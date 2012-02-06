// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class ClosureFieldElement extends Element {
  ClosureFieldElement(SourceString name, ClassElement enclosing)
      : super(name, ElementKind.FIELD, enclosing);

  bool isInstanceMember() => true;
  bool isAssignable() => false;

  String toString() => "ClosureFieldElement($name)";
}

// The box-element for a scope, and the captured variables that need to be
// stored in the box.
class ClosureScope {
  Element boxElement;
  Map<Element, Element> capturedVariableMapping;

  ClosureScope(this.boxElement, this.capturedVariableMapping);
}

class ClosureData {
  // The globalizedClosureElement will be null for methods that are not local
  // closures.
  final ClassElement globalizedClosureElement;
  // The callElement will be null for methods that are not local closures.
  final FunctionElement callElement;

  // Maps free locals, arguments and function elements to their captured
  // copies.
  final Map<Element, Element> freeVariableMapping;
  // Maps closure-fields to their captured elements. This is somehow the inverse
  // mapping of [freeVariableMapping], but whereas [freeVariableMapping] does
  // not deal with boxes, here we map instance-fields (which might represent
  // boxes) to their boxElement.
  final Map<Element, Element> capturedFieldMapping;

  // Maps scopes ([Loop] and [FunctionExpression] nodes) to their
  // [ClosureScope] which contains their box and the
  // captured variables that are stored in the box.
  // This map will be empty if the method/closure of this [ClosureData] does not
  // contain any nested closure.
  final Map<Node, ClosureScope> capturingScopes;

  ClosureData(this.globalizedClosureElement, this.callElement)
      : this.freeVariableMapping = new Map<Element, Element>(),
        this.capturedFieldMapping = new Map<Element, Element>(),
        this.capturingScopes = new Map<Node, ClosureScope>();
}

Map<Node, ClosureData> _closureDataCache;
Map<Node, ClosureData> get closureDataCache() {
  if (_closureDataCache === null) {
    _closureDataCache = new HashMap<Node, ClosureData>();
  }
  return _closureDataCache;
}

class ClosureTranslator extends AbstractVisitor {
  final Compiler compiler;
  final TreeElements elements;

  // Map of captured variables. Initially they will map to themselves. If
  // a variable needs to be boxed then the scope declaring the variable
  // will update this mapping.
  Map<Element, Element> capturedVariableMapping;
  // List of encountered closures.
  List<FunctionExpression> closures;

  // The variables that have been declared in the current scope.
  List<Element> scopeVariables;

  FunctionElement currentFunctionElement;
  // The closureData of the currentFunctionElement.
  ClosureData closureData;

  bool insideClosure = false;

  ClosureTranslator(this.compiler, this.elements)
      : capturedVariableMapping = new Map<Element, Element>(),
        closures = <FunctionExpression>[];

  ClosureData translate(Node node) {
    // Closures have already been analyzed when visiting the surrounding
    // method/function. This also shortcuts for bailout functions.
    ClosureData cached = closureDataCache[node];
    if (cached !== null) return cached;

    visit(node);
    // When variables need to be boxed their [capturedVariableMapping] is
    // updated, but we delay updating the similar freeVariableMapping in the
    // closure datas that capture these variables.
    // The closures don't have their fields (in the closure class) set, either.
    updateClosures();

    return closureDataCache[node];
  }

  // This function runs through all of the existing closures and updates their
  // free variables to the boxed value. It also adds the field-elements to the
  // class representing the closure. At the same time it fills the
  // [capturedFieldMapping].
  void updateClosures() {
    for (FunctionExpression closure in closures) {
      // The captured variables that need to be stored in a field of the closure
      // class.
      Set<Element> fieldCaptures = new Set<Element>();
      ClosureData data = closureDataCache[closure];
      Map<Element, Element> freeVariableMapping = data.freeVariableMapping;
      // We get a copy of the keys and iterate over it, to avoid modifications
      // to the map while iterating over it.
      freeVariableMapping.getKeys().forEach((Element fromElement) {
        assert(fromElement == freeVariableMapping[fromElement]);
        Element updatedElement = capturedVariableMapping[fromElement];
        assert(updatedElement !== null);
        if (fromElement == updatedElement) {
          assert(freeVariableMapping[fromElement] == updatedElement);
          assert(updatedElement.isVariable() || updatedElement.isParameter());
          // The variable has not been boxed.
          fieldCaptures.add(updatedElement);
        } else {
          // A boxed element.
          freeVariableMapping[fromElement] = updatedElement;
          Element boxElement = updatedElement.enclosingElement;
          assert(boxElement.kind == ElementKind.VARIABLE);
          fieldCaptures.add(boxElement);
        }
      });
      ClassElement closureElement = data.globalizedClosureElement;
      assert(closureElement != null || fieldCaptures.isEmpty());
      for (Element boxElement in fieldCaptures) {
        Element fieldElement =
            new ClosureFieldElement(boxElement.name, closureElement);
        closureElement.backendMembers =
            closureElement.backendMembers.prepend(fieldElement);
        data.capturedFieldMapping[fieldElement] = boxElement;
        freeVariableMapping[boxElement] = fieldElement;
      }
    }
  }

  void useLocal(Element element) {
    if (element.enclosingElement != currentFunctionElement) {
      assert(closureData.freeVariableMapping[element] == null ||
             closureData.freeVariableMapping[element] == element);
      closureData.freeVariableMapping[element] = element;
    }
  }

  void declareLocal(Element element) {
    scopeVariables.add(element);
  }

  visit(Node node) => node.accept(this);

  visitNode(Node node) => node.visitChildren(this);

  visitVariableDefinitions(VariableDefinitions node) {
    for (Link<Node> link = node.definitions.nodes;
         !link.isEmpty();
         link = link.tail) {
      Node definition = link.head;
      Element element = elements[definition];
      assert(element !== null);
      declareLocal(element);
    }
    // We still need to visit the right-hand sides of the init-assignments.
    // Simply visit all children. We will visit the locals again and make them
    // used, but that should not be a problem.
    node.visitChildren(this);
  }

  visitIdentifier(Identifier node) {
    // TODO(floitsch): handle 'this'.
    if (node.isThis() && insideClosure) {
      compiler.unimplemented("ClosureAnalyzer.visitIdentifier this-capture",
                             node: node);
    }
    node.visitChildren(this);
  }

  visitSend(Send node) {
    Element element = elements[node];
    if (Elements.isLocal(element)) {
      useLocal(element);
    } else if (element === null && node.receiver === null) {
      if (insideClosure) {
        compiler.unimplemented("ClosureTranslator.visitSend this-capture");
      }
    }
    node.visitChildren(this);
  }

  // If variables that are declared in the [node] scope are captured and need
  // to be boxed create a box-element and update the [capturingScopes] in the
  // current [closureData].
  // The boxed variables are updated in the [capturedVariableMapping].
  void attachCapturedScopeVariables(Node node) {
    Element box = null;
    Map<Element, Element> scopeMapping = new Map<Element, Element>();
    for (Element element in scopeVariables) {
      if (capturedVariableMapping.containsKey(element)) {
        if (box == null) {
          box = new Element(const SourceString("box"),
                            ElementKind.VARIABLE,
                            currentFunctionElement);
        }
        Element boxed = new Element(element.name, ElementKind.FIELD, box);
        scopeMapping[element] = boxed;
        capturedVariableMapping[element] = boxed;
      }
    }
    if (!scopeMapping.isEmpty()) {
      ClosureScope scope = new ClosureScope(box, scopeMapping);
      closureData.capturingScopes[node] = scope;
    }
  }

  visitLoop(Loop node) {
    List<Element> oldScopeVariables = scopeVariables;
    scopeVariables = new List<Element>();
    super.visitLoop(node);
    attachCapturedScopeVariables(node);
    scopeVariables = oldScopeVariables;
  }

  ClosureData globalizeClosure(FunctionExpression node) {
    FunctionElement element = elements[node];
    SourceString name = const SourceString("Closure");
    CompilationUnitElement compilationUnit = element.getCompilationUnit();
    ClassElement globalizedElement = new ClassElement(name, compilationUnit);
    FunctionElement callElement =
        new FunctionElement.from(Namer.CLOSURE_INVOCATION_NAME,
                                 element,
                                 globalizedElement);
    globalizedElement.backendMembers =
        const EmptyLink<Element>().prepend(callElement);
    globalizedElement.isResolved = true;
    ClassElement objectClass =
        compiler.coreLibrary.find(const SourceString('Object'));
    globalizedElement.supertype = new SimpleType(Types.OBJECT, objectClass);
    return new ClosureData(globalizedElement, callElement);
  }

  visitFunctionExpression(FunctionExpression node) {
    bool isClosure = (closureData !== null);

    if (isClosure) closures.add(node);

    bool oldInsideClosure = insideClosure;
    FunctionElement oldFunctionElement = currentFunctionElement;
    ClosureData oldClosureData = closureData;
    List<Element> oldScopeVariables = scopeVariables;


    insideClosure = isClosure;
    currentFunctionElement = elements[node];
    closureData = insideClosure ?
                  globalizeClosure(node) :
                  new ClosureData(null, null);
    scopeVariables = new List<Element>();

    // TODO(floitsch): a named function is visible from inside itself. Add
    // the element to the block.

    node.visitChildren(this);

    attachCapturedScopeVariables(node);

    closureDataCache[node] = closureData;

    ClosureData savedClosureData = closureData;
    bool savedInsideClosure = insideClosure;

    // Restore old values.
    scopeVariables = oldScopeVariables;
    insideClosure = oldInsideClosure;
    closureData = oldClosureData;
    currentFunctionElement = oldFunctionElement;

    // Mark all free variables as captured and use them in the outer function.
    List<Element> freeVariables =
        savedClosureData.freeVariableMapping.getKeys();
    assert(freeVariables.isEmpty() || savedInsideClosure);
    for (Element element in freeVariables) {
      assert(capturedVariableMapping[element] == null ||
             capturedVariableMapping[element] == element);
      capturedVariableMapping[element] = element;
      useLocal(element);
    }

    // If we just visited a closure we declare it. This is not always correct
    // since some closures are used as expressions and don't introduce any
    // name. But in this case the added local is simply not used.
    if (savedInsideClosure) {
      declareLocal(elements[node]);
    }
  }
}
