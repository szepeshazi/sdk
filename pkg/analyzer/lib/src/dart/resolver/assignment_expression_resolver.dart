// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/token.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/element/type_system.dart';
import 'package:analyzer/src/dart/resolver/flow_analysis_visitor.dart';
import 'package:analyzer/src/dart/resolver/invocation_inference_helper.dart';
import 'package:analyzer/src/dart/resolver/resolution_result.dart';
import 'package:analyzer/src/dart/resolver/type_property_resolver.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/error/nullable_dereference_verifier.dart';
import 'package:analyzer/src/generated/migration.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/task/strong/checker.dart';
import 'package:meta/meta.dart';

/// Helper for resolving [AssignmentExpression]s.
class AssignmentExpressionResolver {
  final ResolverVisitor _resolver;
  final FlowAnalysisHelper _flowAnalysis;
  final TypePropertyResolver _typePropertyResolver;
  final InvocationInferenceHelper _inferenceHelper;
  final AssignmentExpressionShared _assignmentShared;

  AssignmentExpressionResolver({
    @required ResolverVisitor resolver,
    @required FlowAnalysisHelper flowAnalysis,
  })  : _resolver = resolver,
        _flowAnalysis = flowAnalysis,
        _typePropertyResolver = resolver.typePropertyResolver,
        _inferenceHelper = resolver.inferenceHelper,
        _assignmentShared = AssignmentExpressionShared(
          resolver: resolver,
          flowAnalysis: flowAnalysis,
        );

  ErrorReporter get _errorReporter => _resolver.errorReporter;

  bool get _isNonNullableByDefault => _typeSystem.isNonNullableByDefault;

  MigrationResolutionHooks get _migrationResolutionHooks {
    return _resolver.migrationResolutionHooks;
  }

  NullableDereferenceVerifier get _nullableDereferenceVerifier =>
      _resolver.nullableDereferenceVerifier;

  TypeProvider get _typeProvider => _resolver.typeProvider;

  TypeSystemImpl get _typeSystem => _resolver.typeSystem;

  void resolve(AssignmentExpressionImpl node) {
    var left = node.leftHandSide;
    var right = node.rightHandSide;

    if (left is SimpleIdentifier) {
      _resolve_SimpleIdentifier(node, left);
      return;
    }

    left?.accept(_resolver);
    left = node.leftHandSide;

    var operator = node.operator.type;
    if (operator != TokenType.EQ) {
      if (node.readElement == null || node.readType == null) {
        _resolver.setReadElement(left, null);
      }
    }
    if (node.writeElement == null || node.writeType == null) {
      _resolver.setWriteElement(left, null);
    }

    _resolve1(node, getReadType(left));

    _setRhsContext(node, left.staticType, operator, right);

    _flowAnalysis?.assignmentExpression(node);

    if (operator != TokenType.EQ &&
        operator != TokenType.QUESTION_QUESTION_EQ) {
      _nullableDereferenceVerifier.expression(left);
    }

    right?.accept(_resolver);
    right = node.rightHandSide;

    _resolve2(node);

    _flowAnalysis?.assignmentExpression_afterRight(node);
  }

  void _checkForInvalidAssignment(
    DartType writeType,
    Expression right,
    DartType rightType,
  ) {
    // TODO(scheglov) should not happen
    if (writeType == null) {
      return;
    }

    if (!writeType.isVoid && _checkForUseOfVoidResult(right)) {
      return;
    }

    if (_typeSystem.isAssignableTo2(rightType, writeType)) {
      return;
    }

    _errorReporter.reportErrorForNode(
      CompileTimeErrorCode.INVALID_ASSIGNMENT,
      right,
      [rightType, writeType],
    );
  }

  /// Check for situations where the result of a method or function is used,
  /// when it returns 'void'. Or, in rare cases, when other types of expressions
  /// are void, such as identifiers.
  ///
  /// See [StaticWarningCode.USE_OF_VOID_RESULT].
  /// TODO(scheglov) this is duplicate
  bool _checkForUseOfVoidResult(Expression expression) {
    if (expression == null ||
        !identical(expression.staticType, VoidTypeImpl.instance)) {
      return false;
    }

    if (expression is MethodInvocation) {
      SimpleIdentifier methodName = expression.methodName;
      _errorReporter.reportErrorForNode(
          CompileTimeErrorCode.USE_OF_VOID_RESULT, methodName, []);
    } else {
      _errorReporter.reportErrorForNode(
          CompileTimeErrorCode.USE_OF_VOID_RESULT, expression, []);
    }

    return true;
  }

  /// Record that the static type of the given node is the given type.
  ///
  /// @param expression the node whose type is to be recorded
  /// @param type the static type of the node
  ///
  /// TODO(scheglov) this is duplication
  void _recordStaticType(Expression expression, DartType type) {
    if (_resolver.migrationResolutionHooks != null) {
      // TODO(scheglov) type cannot be null
      type = _migrationResolutionHooks.modifyExpressionType(
        expression,
        type ?? DynamicTypeImpl.instance,
      );
    }

    // TODO(scheglov) type cannot be null
    if (type == null) {
      expression.staticType = DynamicTypeImpl.instance;
    } else {
      expression.staticType = type;
      if (_typeSystem.isBottom(type)) {
        _flowAnalysis?.flow?.handleExit();
      }
    }
  }

  void _reportNotSetter(
    Expression left,
    Element requested,
    Element recovery,
  ) {
    if (requested != null) {
      if (requested is VariableElement) {
        if (requested.isConst) {
          _errorReporter.reportErrorForNode(
            CompileTimeErrorCode.ASSIGNMENT_TO_CONST,
            left,
          );
        } else if (requested.isFinal) {
          if (_isNonNullableByDefault) {
            // Handled during resolution, with flow analysis.
          } else {
            _errorReporter.reportErrorForNode(
              CompileTimeErrorCode.ASSIGNMENT_TO_FINAL_LOCAL,
              left,
              [requested.name],
            );
          }
        }
      }
      return;
    }

    if (recovery is ClassElement ||
        recovery is DynamicElementImpl ||
        recovery is FunctionTypeAliasElement ||
        recovery is TypeParameterElement) {
      _errorReporter.reportErrorForNode(
        CompileTimeErrorCode.ASSIGNMENT_TO_TYPE,
        left,
      );
    } else if (recovery is FunctionElement) {
      _errorReporter.reportErrorForNode(
        CompileTimeErrorCode.ASSIGNMENT_TO_FUNCTION,
        left,
      );
    } else if (recovery is MethodElement) {
      _errorReporter.reportErrorForNode(
        CompileTimeErrorCode.ASSIGNMENT_TO_METHOD,
        left,
      );
    } else if (recovery is PrefixElement) {
      _errorReporter.reportErrorForNode(
        CompileTimeErrorCode.PREFIX_IDENTIFIER_NOT_FOLLOWED_BY_DOT,
        left,
        [recovery.name],
      );
    } else if (recovery is PropertyAccessorElement && recovery.isGetter) {
      var variable = recovery.variable;
      if (variable.isConst) {
        _errorReporter.reportErrorForNode(
          CompileTimeErrorCode.ASSIGNMENT_TO_CONST,
          left,
        );
      } else if (variable is FieldElement && variable.isSynthetic) {
        _errorReporter.reportErrorForNode(
          CompileTimeErrorCode.ASSIGNMENT_TO_FINAL_NO_SETTER,
          left,
          [variable.name, variable.enclosingElement.displayName],
        );
      } else {
        _errorReporter.reportErrorForNode(
          CompileTimeErrorCode.ASSIGNMENT_TO_FINAL,
          left,
          [variable.name],
        );
      }
    } else if (recovery is MultiplyDefinedElementImpl) {
      // Will be reported in ErrorVerifier.
    } else {
      if (left is SimpleIdentifier && !left.isSynthetic) {
        _errorReporter.reportErrorForNode(
          CompileTimeErrorCode.UNDEFINED_IDENTIFIER,
          left,
          [left.name],
        );
      }
    }
  }

  void _resolve1(AssignmentExpressionImpl node, DartType leftType) {
    Token operator = node.operator;
    TokenType operatorType = operator.type;
    Expression leftHandSide = node.leftHandSide;

    if (identical(leftType, NeverTypeImpl.instance)) {
      return;
    }

    _assignmentShared.checkFinalAlreadyAssigned(leftHandSide);

    // For any compound assignments to a void or nullable variable, report it.
    // Example: `y += voidFn()`, not allowed.
    if (operatorType != TokenType.EQ) {
      if (leftType != null && leftType.isVoid) {
        _errorReporter.reportErrorForToken(
          CompileTimeErrorCode.USE_OF_VOID_RESULT,
          operator,
        );
        return;
      }
    }

    if (operatorType != TokenType.AMPERSAND_AMPERSAND_EQ &&
        operatorType != TokenType.BAR_BAR_EQ &&
        operatorType != TokenType.EQ &&
        operatorType != TokenType.QUESTION_QUESTION_EQ) {
      operatorType = operatorFromCompoundAssignment(operatorType);
      if (leftHandSide != null) {
        String methodName = operatorType.lexeme;
        // TODO(brianwilkerson) Change the [methodNameNode] from the left hand
        //  side to the operator.
        var result = _typePropertyResolver.resolve(
          receiver: leftHandSide,
          receiverType: leftType,
          name: methodName,
          receiverErrorNode: leftHandSide,
          nameErrorNode: leftHandSide,
        );
        node.staticElement = result.getter;
        if (_shouldReportInvalidMember(leftType, result)) {
          _errorReporter.reportErrorForToken(
            CompileTimeErrorCode.UNDEFINED_OPERATOR,
            operator,
            [methodName, leftType],
          );
        }
      }
    }
  }

  void _resolve2(AssignmentExpressionImpl node) {
    TokenType operator = node.operator.type;
    if (operator == TokenType.EQ) {
      var rightType = node.rightHandSide.staticType;
      _inferenceHelper.recordStaticType(node, rightType);
    } else if (operator == TokenType.QUESTION_QUESTION_EQ) {
      var leftType = node.readType;

      // The LHS value will be used only if it is non-null.
      if (_isNonNullableByDefault) {
        leftType = _typeSystem.promoteToNonNull(leftType);
      }

      var rightType = node.rightHandSide.staticType;
      var result = _typeSystem.getLeastUpperBound(leftType, rightType);

      _inferenceHelper.recordStaticType(node, result);
    } else if (operator == TokenType.AMPERSAND_AMPERSAND_EQ ||
        operator == TokenType.BAR_BAR_EQ) {
      _inferenceHelper.recordStaticType(node, _typeProvider.boolType);
    } else {
      var rightType = node.rightHandSide.staticType;

      var leftReadType = getReadType(node.leftHandSide);
      if (identical(leftReadType, NeverTypeImpl.instance)) {
        _inferenceHelper.recordStaticType(node, rightType);
        return;
      }

      var operatorElement = node.staticElement;
      var type = operatorElement?.returnType ?? DynamicTypeImpl.instance;
      type = _typeSystem.refineBinaryExpressionType(
        leftReadType,
        operator,
        rightType,
        type,
        operatorElement,
      );
      _inferenceHelper.recordStaticType(node, type);

      var leftWriteType = _getWriteType(node.leftHandSide);
      if (!_typeSystem.isAssignableTo2(type, leftWriteType)) {
        _resolver.errorReporter.reportErrorForNode(
          CompileTimeErrorCode.INVALID_ASSIGNMENT,
          node.rightHandSide,
          [type, leftWriteType],
        );
      }
    }
    _resolver.nullShortingTermination(node);
  }

  void _resolve_SimpleIdentifier(
    AssignmentExpressionImpl node,
    SimpleIdentifier left,
  ) {
    var right = node.rightHandSide;
    var operator = node.operator.type;

    if (operator != TokenType.EQ) {
      var readLookup = _resolver.lexicalLookup(node: left, setter: false);
      var readElement = readLookup.requested;
      _resolver.setReadElement(left, readElement);
    }

    var writeLookup = _resolver.lexicalLookup(node: left, setter: true);
    var writeElement = writeLookup.requested ?? writeLookup.recovery;
    _resolver.setWriteElement(left, writeElement);
    _reportNotSetter(left, writeLookup.requested, writeLookup.recovery);

    // TODO(scheglov) This is mostly necessary for backward compatibility.
    // Although we also use `staticElement` for `getType(left)` below.
    {
      if (operator != TokenType.EQ) {
        var readElement = node.readElement;
        if (readElement is PropertyAccessorElement) {
          left.auxiliaryElements = AuxiliaryElements(readElement);
        }
      }
      left.staticElement = node.writeElement;
      if (node.readElement is VariableElement) {
        var leftType = _resolver.localVariableTypeProvider.getType(left);
        _recordStaticType(left, leftType);
      } else {
        _recordStaticType(left, node.writeType);
      }
    }

    if (operator != TokenType.EQ) {
      // TODO(scheglov) Change this method to work with elements.
      _resolver.checkReadOfNotAssignedLocalVariable(left);
    }

    _resolve1(node, node.readType);

    {
      var leftType = node.writeType;
      if (node.writeElement is VariableElement) {
        leftType = _resolver.localVariableTypeProvider.getType(left);
      }
      _setRhsContext(node, leftType, operator, right);
    }

    var flow = _flowAnalysis?.flow;
    if (flow != null && operator == TokenType.QUESTION_QUESTION_EQ) {
      flow.ifNullExpression_rightBegin(left, node.readType);
    }

    right?.accept(_resolver);
    right = node.rightHandSide;

    _resolve2(node);

    // TODO(scheglov) inline into resolve2().
    DartType assignedType;
    if (operator == TokenType.EQ ||
        operator == TokenType.QUESTION_QUESTION_EQ) {
      assignedType = right.staticType;
    } else {
      assignedType = node.staticType;
    }
    _checkForInvalidAssignment(node.writeType, right, assignedType);

    if (flow != null) {
      if (writeElement is VariableElement) {
        flow.write(writeElement, node.staticType);
      }
      if (node.operator.type == TokenType.QUESTION_QUESTION_EQ) {
        flow.ifNullExpression_end();
      }
    }
  }

  void _setRhsContext(AssignmentExpressionImpl node, DartType leftType,
      TokenType operator, Expression right) {
    switch (operator) {
      case TokenType.EQ:
      case TokenType.QUESTION_QUESTION_EQ:
        InferenceContext.setType(right, leftType);
        break;
      case TokenType.AMPERSAND_AMPERSAND_EQ:
      case TokenType.BAR_BAR_EQ:
        InferenceContext.setType(right, _typeProvider.boolType);
        break;
      default:
        var method = node.staticElement;
        if (method != null) {
          var parameters = method.parameters;
          if (parameters.isNotEmpty) {
            InferenceContext.setType(
                right,
                _typeSystem.refineNumericInvocationContext(
                    leftType, method, leftType, parameters[0].type));
          }
        }
        break;
    }
  }

  /// Return `true` if we should report an error for the lookup [result] on
  /// the [type].
  // TODO(scheglov) this is duplicate
  bool _shouldReportInvalidMember(DartType type, ResolutionResult result) {
    if (result.isNone && type != null && !type.isDynamic) {
      if (_typeSystem.isNonNullableByDefault &&
          _typeSystem.isPotentiallyNullable(type)) {
        return false;
      }
      return true;
    }
    return false;
  }

  /// The type of the RHS assigned to [left] must be subtype of the return.
  static DartType _getWriteType(Expression left) {
    // We are writing, so ignore promotions.
    if (left is SimpleIdentifier) {
      var element = left.staticElement;
      if (element is PromotableElement) {
        return element.type;
      }
    }

    return left.staticType;
  }
}

class AssignmentExpressionShared {
  final ResolverVisitor _resolver;
  final FlowAnalysisHelper _flowAnalysis;

  AssignmentExpressionShared({
    @required ResolverVisitor resolver,
    @required FlowAnalysisHelper flowAnalysis,
  })  : _resolver = resolver,
        _flowAnalysis = flowAnalysis;

  ErrorReporter get _errorReporter => _resolver.errorReporter;

  void checkFinalAlreadyAssigned(Expression left) {
    var flow = _flowAnalysis?.flow;
    if (flow != null && left is SimpleIdentifier) {
      var element = left.staticElement;
      if (element is VariableElement) {
        var assigned = _flowAnalysis.isDefinitelyAssigned(left, element);
        var unassigned = _flowAnalysis.isDefinitelyUnassigned(left, element);

        if (element.isFinal) {
          if (element.isLate) {
            if (assigned) {
              _errorReporter.reportErrorForNode(
                CompileTimeErrorCode.LATE_FINAL_LOCAL_ALREADY_ASSIGNED,
                left,
              );
            }
          } else {
            if (!unassigned) {
              _errorReporter.reportErrorForNode(
                CompileTimeErrorCode.ASSIGNMENT_TO_FINAL_LOCAL,
                left,
                [element.name],
              );
            }
          }
        }
      }
    }
  }
}
