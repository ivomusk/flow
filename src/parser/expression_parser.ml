(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Token
open Parser_env
open Flow_ast
open Parser_common
open Comment_attachment

module Expression
    (Parse : PARSER)
    (Type : Parser_common.TYPE)
    (Declaration : Parser_common.DECLARATION)
    (Pattern_cover : Parser_common.COVER) : Parser_common.EXPRESSION = struct
  type op_precedence =
    | Left_assoc of int
    | Right_assoc of int

  type group_cover =
    | Group_expr of (Loc.t, Loc.t) Expression.t
    | Group_typecast of (Loc.t, Loc.t) Expression.TypeCast.t

  let is_tighter a b =
    let a_prec =
      match a with
      | Left_assoc x -> x
      | Right_assoc x -> x - 1
    in
    let b_prec =
      match b with
      | Left_assoc x -> x
      | Right_assoc x -> x
    in
    a_prec >= b_prec

  let rec is_assignable_lhs =
    let open Expression in
    function
    | ( _,
        MetaProperty
          {
            MetaProperty.meta = (_, { Identifier.name = "new"; comments = _ });
            property = (_, { Identifier.name = "target"; comments = _ });
            comments = _;
          }
      ) ->
      false
    | ( _,
        MetaProperty
          {
            MetaProperty.meta = (_, { Identifier.name = "import"; comments = _ });
            property = (_, { Identifier.name = "meta"; comments = _ });
            comments = _;
          }
      ) ->
      false
    (* #sec-static-semantics-static-semantics-isvalidsimpleassignmenttarget *)
    | (_, Array _)
    | (_, Identifier _)
    | (_, Member _)
    | (_, MetaProperty _)
    | (_, Object _) ->
      true
    | (_, Unary { Unary.operator = Unary.Nonnull; argument; _ }) -> is_assignable_lhs argument
    | (_, ArrowFunction _)
    | (_, AsConstExpression _)
    | (_, AsExpression _)
    | (_, Assignment _)
    | (_, Binary _)
    | (_, Call _)
    | (_, Class _)
    | (_, Conditional _)
    | (_, Function _)
    | (_, Import _)
    | (_, JSXElement _)
    | (_, JSXFragment _)
    | (_, StringLiteral _)
    | (_, BooleanLiteral _)
    | (_, NullLiteral _)
    | (_, NumberLiteral _)
    | (_, BigIntLiteral _)
    | (_, RegExpLiteral _)
    | (_, Match _)
    | (_, ModuleRefLiteral _)
    | (_, Logical _)
    | (_, New _)
    | (_, OptionalCall _)
    | (_, OptionalMember _)
    | (_, Sequence _)
    | (_, Super _)
    | (_, TaggedTemplate _)
    | (_, TemplateLiteral _)
    | (_, This _)
    | (_, TypeCast _)
    | (_, TSSatisfies _)
    | (_, Unary _)
    | (_, Update _)
    | (_, Yield _) ->
      false

  let as_expression = Pattern_cover.as_expression

  let as_pattern = Pattern_cover.as_pattern

  (* AssignmentExpression :
   *   [+Yield] YieldExpression
   *   ConditionalExpression
   *   LeftHandSideExpression = AssignmentExpression
   *   LeftHandSideExpression AssignmentOperator AssignmentExpression
   *   ArrowFunctionFunction
   *
   *   Originally we were parsing this without backtracking, but
   *   ArrowFunctionExpression got too tricky. Oh well.
   *)
  let rec assignment_cover =
    let assignment_but_not_arrow_function_cover env =
      let start_loc = Peek.loc env in
      let expr_or_pattern = conditional_cover env in
      match assignment_op env with
      | Some operator ->
        let expr =
          with_loc
            ~start_loc
            (fun env ->
              let left = as_pattern env expr_or_pattern in
              let right = assignment env in
              Expression.(Assignment { Assignment.operator; left; right; comments = None }))
            env
        in
        Cover_expr expr
      | _ -> expr_or_pattern
    in
    let error_callback _ = function
      (* Don't rollback on these errors. *)
      | Parse_error.StrictReservedWord -> ()
      (* Everything else causes a rollback *)
      | _ -> raise Try.Rollback
      (* So we may or may not be parsing the first part of an arrow function
       * (the part before the =>). We might end up parsing that whole thing or
       * we might end up parsing only part of it and thinking we're done. We
       * need to look at the next token to figure out if we really parsed an
       * assignment expression or if this is just the beginning of an arrow
       * function *)
    in
    let try_assignment_but_not_arrow_function env =
      let env = env |> with_error_callback error_callback in
      let ret = assignment_but_not_arrow_function_cover env in
      match Peek.token env with
      | T_ARROW ->
        (* x => 123 *)
        raise Try.Rollback
      | T_COLON
        when match last_token env with
             | Some T_RPAREN -> true
             | _ -> false ->
        (* (x): number => 123 *)
        raise Try.Rollback
      (* async x => 123 -- and we've already parsed async as an identifier
       * expression *)
      | _ when Peek.is_identifier env -> begin
        match ret with
        | Cover_expr (_, Expression.Identifier (_, { Identifier.name = "async"; comments = _ }))
          when not (Peek.is_line_terminator env) ->
          raise Try.Rollback
        | _ -> ret
      end
      | _ -> ret
    in
    fun env ->
      let is_identifier =
        Peek.is_identifier env
        &&
        match Peek.token env with
        | T_AWAIT when allow_await env -> false
        | T_YIELD when allow_yield env -> false
        | _ -> true
      in
      match (Peek.token env, is_identifier) with
      | (T_YIELD, _) when allow_yield env -> Cover_expr (yield env)
      | ((T_LPAREN as t), _)
      | ((T_LESS_THAN as t), _)
      | ((T_THIS as t), _)
      | (t, true) ->
        (* Ok, we don't know if this is going to be an arrow function or a
         * regular assignment expression. Let's first try to parse it as an
         * assignment expression. If that fails we'll try an arrow function.
         * Unless it begins with `async <` in which case we first try parsing
         * it as an arrow function, and then an assignment expression.
         *)
        let (initial, secondary) =
          if t = T_ASYNC && should_parse_types env && Peek.ith_token ~i:1 env = T_LESS_THAN then
            (try_arrow_function, try_assignment_but_not_arrow_function)
          else
            (try_assignment_but_not_arrow_function, try_arrow_function)
        in
        (match Try.to_parse env initial with
        | Try.ParsedSuccessfully expr -> expr
        | Try.FailedToParse ->
          (match Try.to_parse env secondary with
          | Try.ParsedSuccessfully expr -> expr
          | Try.FailedToParse ->
            (* Well shoot. It doesn't parse cleanly as a normal
             * expression or as an arrow_function. Let's treat it as a
             * normal assignment expression gone wrong *)
            assignment_but_not_arrow_function_cover env))
      | _ -> assignment_but_not_arrow_function_cover env

  and assignment env = as_expression env (assignment_cover env)

  and yield env =
    with_loc
      (fun env ->
        if in_formal_parameters env then error env Parse_error.YieldInFormalParameters;
        if in_match_expression env then error env Parse_error.MatchExpressionYield;
        let leading = Peek.comments env in
        let start_loc = Peek.loc env in
        Expect.token env T_YIELD;
        let end_loc = Peek.loc env in
        let (argument, delegate) =
          if Peek.is_implicit_semicolon env then
            (None, false)
          else
            let delegate = Eat.maybe env T_MULT in
            let has_argument =
              match Peek.token env with
              | T_SEMICOLON
              | T_RBRACKET
              | T_RCURLY
              | T_RPAREN
              | T_COLON
              | T_COMMA ->
                false
              | _ -> true
            in
            let argument =
              if delegate || has_argument then
                Some (assignment env)
              else
                None
            in
            (argument, delegate)
        in
        let trailing =
          match argument with
          | None -> Eat.trailing_comments env
          | Some _ -> []
        in
        let open Expression in
        Yield
          Yield.
            {
              argument;
              delegate;
              comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing ();
              result_out = Loc.btwn start_loc end_loc;
            })
      env

  and is_lhs =
    let open Expression in
    function
    | ( _,
        MetaProperty
          {
            MetaProperty.meta = (_, { Identifier.name = "new"; comments = _ });
            property = (_, { Identifier.name = "target"; comments = _ });
            comments = _;
          }
      ) ->
      false
    | ( _,
        MetaProperty
          {
            MetaProperty.meta = (_, { Identifier.name = "import"; comments = _ });
            property = (_, { Identifier.name = "meta"; comments = _ });
            comments = _;
          }
      ) ->
      false
    (* #sec-static-semantics-static-semantics-isvalidsimpleassignmenttarget *)
    | (_, Identifier _)
    | (_, Member _)
    | (_, MetaProperty _) ->
      true
    | (_, Unary { Unary.operator = Unary.Nonnull; argument; _ }) -> is_lhs argument
    | (_, Array _)
    | (_, ArrowFunction _)
    | (_, AsConstExpression _)
    | (_, AsExpression _)
    | (_, Assignment _)
    | (_, Binary _)
    | (_, Call _)
    | (_, Class _)
    | (_, Conditional _)
    | (_, Function _)
    | (_, Import _)
    | (_, JSXElement _)
    | (_, JSXFragment _)
    | (_, StringLiteral _)
    | (_, BooleanLiteral _)
    | (_, NullLiteral _)
    | (_, NumberLiteral _)
    | (_, BigIntLiteral _)
    | (_, RegExpLiteral _)
    | (_, ModuleRefLiteral _)
    | (_, Logical _)
    | (_, Match _)
    | (_, New _)
    | (_, Object _)
    | (_, OptionalCall _)
    | (_, OptionalMember _)
    | (_, Sequence _)
    | (_, Super _)
    | (_, TaggedTemplate _)
    | (_, TemplateLiteral _)
    | (_, This _)
    | (_, TypeCast _)
    | (_, TSSatisfies _)
    | (_, Unary _)
    | (_, Update _)
    | (_, Yield _) ->
      false

  and assignment_op env =
    let op =
      let open Expression.Assignment in
      match Peek.token env with
      | T_RSHIFT3_ASSIGN -> Some (Some RShift3Assign)
      | T_RSHIFT_ASSIGN -> Some (Some RShiftAssign)
      | T_LSHIFT_ASSIGN -> Some (Some LShiftAssign)
      | T_BIT_XOR_ASSIGN -> Some (Some BitXorAssign)
      | T_BIT_OR_ASSIGN -> Some (Some BitOrAssign)
      | T_BIT_AND_ASSIGN -> Some (Some BitAndAssign)
      | T_MOD_ASSIGN -> Some (Some ModAssign)
      | T_DIV_ASSIGN -> Some (Some DivAssign)
      | T_MULT_ASSIGN -> Some (Some MultAssign)
      | T_EXP_ASSIGN -> Some (Some ExpAssign)
      | T_MINUS_ASSIGN -> Some (Some MinusAssign)
      | T_PLUS_ASSIGN -> Some (Some PlusAssign)
      | T_NULLISH_ASSIGN -> Some (Some NullishAssign)
      | T_AND_ASSIGN -> Some (Some AndAssign)
      | T_OR_ASSIGN -> Some (Some OrAssign)
      | T_ASSIGN -> Some None
      | _ -> None
    in
    if op <> None then Eat.token env;
    op

  (* ConditionalExpression :
   *   LogicalExpression
   *   LogicalExpression ? AssignmentExpression : AssignmentExpression
   *)
  and conditional_cover env =
    let start_loc = Peek.loc env in
    let expr = logical_cover env in
    if Peek.token env = T_PLING then (
      Eat.token env;

      (* no_in is ignored for the consequent *)
      let env' = env |> with_no_in false in
      let consequent = assignment env' in
      Expect.token env T_COLON;
      let (loc, alternate) = with_loc ~start_loc assignment env in
      Cover_expr
        ( loc,
          let open Expression in
          Conditional
            { Conditional.test = as_expression env expr; consequent; alternate; comments = None }
        )
    ) else
      expr

  and conditional env = as_expression env (conditional_cover env)

  (*
   * LogicalANDExpression :
   *   BinaryExpression
   *   LogicalANDExpression && BitwiseORExpression
   *
   * LogicalORExpression :
   *   LogicalANDExpression
   *   LogicalORExpression || LogicalANDExpression
   *   LogicalORExpression ?? LogicalANDExpression
   *
   * LogicalExpression :
   *   LogicalORExpression
   *)
  and logical_cover =
    let open Expression in
    let make_logical env left right operator loc =
      let left = as_expression env left in
      let right = as_expression env right in
      Cover_expr (loc, Logical { Logical.operator; left; right; comments = None })
    in
    let rec logical_and env left lloc =
      match Peek.token env with
      | T_AND ->
        Eat.token env;
        let (rloc, right) = with_loc binary_cover env in
        let loc = Loc.btwn lloc rloc in
        let left = make_logical env left right Logical.And loc in
        (* `a && b ?? c` is an error, but to recover, try to parse it like `(a && b) ?? c`. *)
        let (loc, left) = coalesce ~allowed:false env left loc in
        logical_and env left loc
      | _ -> (lloc, left)
    and logical_or env left lloc =
      match Peek.token env with
      | T_OR ->
        Eat.token env;
        let (rloc, right) = with_loc binary_cover env in
        let (rloc, right) = logical_and env right rloc in
        let loc = Loc.btwn lloc rloc in
        let left = make_logical env left right Logical.Or loc in
        (* `a || b ?? c` is an error, but to recover, try to parse it like `(a || b) ?? c`. *)
        let (loc, left) = coalesce ~allowed:false env left loc in
        logical_or env left loc
      | _ -> (lloc, left)
    and coalesce ~allowed env left lloc =
      match Peek.token env with
      | T_PLING_PLING ->
        if not allowed then error env (Parse_error.NullishCoalescingUnexpectedLogical "??");

        Expect.token env T_PLING_PLING;
        let (rloc, right) = with_loc binary_cover env in
        let (rloc, right) =
          match Peek.token env with
          | (T_AND | T_OR) as t ->
            (* `a ?? b || c` is an error. To recover, treat it like `a ?? (b || c)`. *)
            error env (Parse_error.NullishCoalescingUnexpectedLogical (Token.value_of_token t));
            let (rloc, right) = logical_and env right rloc in
            logical_or env right rloc
          | _ -> (rloc, right)
        in
        let loc = Loc.btwn lloc rloc in
        coalesce ~allowed:true env (make_logical env left right Logical.NullishCoalesce loc) loc
      | _ -> (lloc, left)
    in
    fun env ->
      let (loc, left) = with_loc binary_cover env in
      let (_, left) =
        match Peek.token env with
        | T_PLING_PLING -> coalesce ~allowed:true env left loc
        | _ ->
          let (loc, left) = logical_and env left loc in
          logical_or env left loc
      in
      left

  and binary_cover =
    let binary_op env =
      let ret =
        let open Expression.Binary in
        match Peek.token env with
        (* Most BinaryExpression operators are left associative *)
        (* Lowest pri *)
        | T_BIT_OR -> Some (BitOr, Left_assoc 2)
        | T_BIT_XOR -> Some (Xor, Left_assoc 3)
        | T_BIT_AND -> Some (BitAnd, Left_assoc 4)
        | T_EQUAL -> Some (Equal, Left_assoc 5)
        | T_STRICT_EQUAL -> Some (StrictEqual, Left_assoc 5)
        | T_NOT_EQUAL -> Some (NotEqual, Left_assoc 5)
        | T_STRICT_NOT_EQUAL -> Some (StrictNotEqual, Left_assoc 5)
        | T_LESS_THAN -> Some (LessThan, Left_assoc 6)
        | T_LESS_THAN_EQUAL -> Some (LessThanEqual, Left_assoc 6)
        | T_GREATER_THAN -> Some (GreaterThan, Left_assoc 6)
        | T_GREATER_THAN_EQUAL -> Some (GreaterThanEqual, Left_assoc 6)
        | T_IN ->
          if no_in env then
            None
          else
            Some (In, Left_assoc 6)
        | T_INSTANCEOF -> Some (Instanceof, Left_assoc 6)
        | T_LSHIFT -> Some (LShift, Left_assoc 7)
        | T_RSHIFT -> Some (RShift, Left_assoc 7)
        | T_RSHIFT3 -> Some (RShift3, Left_assoc 7)
        | T_PLUS -> Some (Plus, Left_assoc 8)
        | T_MINUS -> Some (Minus, Left_assoc 8)
        | T_MULT -> Some (Mult, Left_assoc 9)
        | T_DIV -> Some (Div, Left_assoc 9)
        | T_MOD -> Some (Mod, Left_assoc 9)
        | T_EXP -> Some (Exp, Right_assoc 10)
        (* Highest priority *)
        | _ -> None
      in
      if ret <> None then Eat.token env;
      ret
    in
    let make_binary left right operator loc =
      (loc, Expression.(Binary Binary.{ operator; left; right; comments = None }))
    in
    let rec add_to_stack right (rop, rpri) rloc = function
      | (left, (lop, lpri), lloc) :: rest when is_tighter lpri rpri ->
        let loc = Loc.btwn lloc rloc in
        let right = make_binary left right lop loc in
        add_to_stack right (rop, rpri) loc rest
      | stack -> (right, (rop, rpri), rloc) :: stack
    in
    let rec collapse_stack right rloc = function
      | [] -> right
      | (left, (lop, _), lloc) :: rest ->
        let loc = Loc.btwn lloc rloc in
        collapse_stack (make_binary left right lop loc) loc rest
    in
    let rec helper env stack =
      let (expr_loc, (is_unary, expr)) =
        with_loc
          (fun env ->
            let is_unary = peek_unary_op env <> None in
            let expr = unary_cover (env |> with_no_in false) in
            (is_unary, expr))
          env
      in
      let next = Peek.token env in
      ( if next = T_LESS_THAN then
        match expr with
        | Cover_expr (_, Expression.JSXElement _) -> error env Parse_error.AdjacentJSXElements
        | _ -> ()
      );
      let (stack, expr) =
        let rec loop stack expr =
          match Peek.token env with
          | T_IDENTIFIER { raw = ("as" | "satisfies") as keyword; _ } when should_parse_types env ->
            Eat.token env;
            let expr = as_expression env expr in
            let (stack, expr) =
              match stack with
              | (left, (lop, lpri), lloc) :: rest when is_tighter lpri (Left_assoc 6) ->
                let expr_loc = Loc.btwn lloc expr_loc in
                let expr = make_binary left expr lop expr_loc in
                (rest, expr)
              | _ -> (stack, expr)
            in
            let (expr_loc, _) = expr in
            let expr =
              if keyword = "satisfies" then
                let ((annot_loc, _) as annot) = Type._type env in
                let loc = Loc.btwn expr_loc annot_loc in
                Cover_expr
                  ( loc,
                    Expression.TSSatisfies
                      {
                        Expression.TSSatisfies.expression = expr;
                        annot = (annot_loc, annot);
                        comments = None;
                      }
                  )
              else if Peek.token env = T_CONST then (
                let loc = Loc.btwn expr_loc (Peek.loc env) in
                Eat.token env;
                Cover_expr
                  ( loc,
                    Expression.AsConstExpression
                      { Expression.AsConstExpression.expression = expr; comments = None }
                  )
              ) else
                let ((annot_loc, _) as annot) = Type._type env in
                let loc = Loc.btwn expr_loc annot_loc in
                Cover_expr
                  ( loc,
                    Expression.AsExpression
                      {
                        Expression.AsExpression.expression = expr;
                        annot = (annot_loc, annot);
                        comments = None;
                      }
                  )
            in
            loop stack expr
          | _ -> (stack, expr)
        in
        loop stack expr
      in

      match (stack, binary_op env) with
      | ([], None) -> expr
      | (_, None) ->
        let expr = as_expression env expr in
        Cover_expr (collapse_stack expr expr_loc stack)
      | (_, Some (rop, rpri)) ->
        if is_unary && rop = Expression.Binary.Exp then
          error_at env (expr_loc, Parse_error.InvalidLHSInExponentiation);
        let expr = as_expression env expr in
        helper env (add_to_stack expr (rop, rpri) expr_loc stack)
    in
    (fun env -> helper env [])

  and peek_unary_op env =
    let open Expression.Unary in
    match Peek.token env with
    | T_NOT -> Some Not
    | T_BIT_NOT -> Some BitNot
    | T_PLUS -> Some Plus
    | T_MINUS -> Some Minus
    | T_TYPEOF -> Some Typeof
    | T_VOID -> Some Void
    | T_DELETE -> Some Delete
    (* If we are in a unary expression context, and within an async function,
     * assume that a use of "await" is intended as a keyword, not an ordinary
     * identifier. This is a little bit inconsistent, since it can be used as
     * an identifier in other contexts (such as a variable name), but it's how
     * Babel does it. *)
    | T_AWAIT when allow_await env ->
      if in_formal_parameters env then error env Parse_error.AwaitInAsyncFormalParameters;
      if in_match_expression env then error env Parse_error.MatchExpressionAwait;
      Some Await
    | _ -> None

  and unary_cover env =
    let start_loc = Peek.loc env in
    let leading = Peek.comments env in
    let op = peek_unary_op env in
    match op with
    | None ->
      let op =
        let open Expression.Update in
        match Peek.token env with
        | T_INCR -> Some Increment
        | T_DECR -> Some Decrement
        | _ -> None
      in
      (match op with
      | None -> postfix_cover env
      | Some operator ->
        Eat.token env;
        let (loc, argument) = with_loc ~start_loc unary env in
        if not (is_lhs argument) then error_at env (fst argument, Parse_error.InvalidLHSInAssignment);
        (match argument with
        | (_, Expression.Identifier (_, { Identifier.name; comments = _ })) when is_restricted name
          ->
          strict_error env Parse_error.StrictLHSPrefix
        | _ -> ());
        Cover_expr
          ( loc,
            Expression.(
              Update
                {
                  Update.operator;
                  prefix = true;
                  argument;
                  comments = Flow_ast_utils.mk_comments_opt ~leading ();
                }
            )
          ))
    | Some operator ->
      Eat.token env;
      let (loc, argument) = with_loc ~start_loc unary env in
      let open Expression in
      (match (operator, argument) with
      | (Unary.Delete, (_, Identifier _)) -> strict_error_at env (loc, Parse_error.StrictDelete)
      | (Unary.Delete, (_, Member member)) -> begin
        match member.Ast.Expression.Member.property with
        | Ast.Expression.Member.PropertyPrivateName _ ->
          error_at env (loc, Parse_error.PrivateDelete)
        | _ -> ()
      end
      | _ -> ());
      Cover_expr
        ( loc,
          let open Expression in
          Unary { Unary.operator; argument; comments = Flow_ast_utils.mk_comments_opt ~leading () }
        )

  and unary env = as_expression env (unary_cover env)

  and postfix_cover env =
    let argument = left_hand_side_cover env in
    (* No line terminator allowed before operator *)
    if Peek.is_line_terminator env then
      argument
    else
      let op =
        let open Expression.Update in
        match Peek.token env with
        | T_INCR -> Some Increment
        | T_DECR -> Some Decrement
        | _ -> None
      in
      match op with
      | None -> argument
      | Some operator ->
        let argument = as_expression env argument in
        if not (is_lhs argument) then error_at env (fst argument, Parse_error.InvalidLHSInAssignment);
        (match argument with
        | (_, Expression.Identifier (_, { Identifier.name; comments = _ })) when is_restricted name
          ->
          strict_error env Parse_error.StrictLHSPostfix
        | _ -> ());
        let end_loc = Peek.loc env in
        Eat.token env;
        let trailing = Eat.trailing_comments env in
        let loc = Loc.btwn (fst argument) end_loc in
        Cover_expr
          ( loc,
            Expression.(
              Update
                {
                  Update.operator;
                  prefix = false;
                  argument;
                  comments = Flow_ast_utils.mk_comments_opt ~trailing ();
                }
            )
          )

  and left_hand_side_cover env =
    let start_loc = Peek.loc env in
    let allow_new = not (no_new env) in
    let env = with_no_new false env in
    let expr =
      match Peek.token env with
      | T_NEW when allow_new -> Cover_expr (new_expression env)
      | T_IMPORT -> Cover_expr (import env)
      | T_SUPER -> Cover_expr (super env)
      | _ when Peek.is_function env -> Cover_expr (_function env)
      | _ -> primary_cover env
    in
    call_cover env start_loc expr

  and left_hand_side env = as_expression env (left_hand_side_cover env)

  and super env =
    let (allowed, call_allowed) =
      match allow_super env with
      | No_super -> (false, false)
      | Super_prop -> (true, false)
      | Super_prop_or_call -> (true, true)
    in
    let loc = Peek.loc env in
    let leading = Peek.comments env in
    Expect.token env T_SUPER;
    let trailing = Eat.trailing_comments env in
    let super =
      ( loc,
        Expression.Super
          { Expression.Super.comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing () }
      )
    in
    match Peek.token env with
    | T_PERIOD
    | T_LBRACKET ->
      let super =
        if not allowed then (
          error_at env (loc, Parse_error.UnexpectedSuper);
          (loc, Expression.Identifier (Flow_ast_utils.ident_of_source (loc, "super")))
        ) else
          super
      in
      call env loc super
    | T_LPAREN ->
      let super =
        if not call_allowed then (
          error_at env (loc, Parse_error.UnexpectedSuperCall);
          (loc, Expression.Identifier (Flow_ast_utils.ident_of_source (loc, "super")))
        ) else
          super
      in
      call env loc super
    | _ ->
      if not allowed then
        error_at env (loc, Parse_error.UnexpectedSuper)
      else
        error_unexpected ~expected:"either a call or access of `super`" env;
      super

  and import env =
    with_loc
      (fun env ->
        let leading = Peek.comments env in
        let start_loc = Peek.loc env in
        Expect.token env T_IMPORT;
        if Eat.maybe env T_PERIOD then (
          (* import.meta *)
          let import_ident = Flow_ast_utils.ident_of_source (start_loc, "import") in
          let meta_loc = Peek.loc env in
          Expect.identifier env "meta";
          let meta_ident = Flow_ast_utils.ident_of_source (meta_loc, "meta") in
          let trailing = Eat.trailing_comments env in
          Expression.MetaProperty
            {
              Expression.MetaProperty.meta = import_ident;
              property = meta_ident;
              comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing ();
            }
        ) else
          let leading_arg = Peek.comments env in
          Expect.token env T_LPAREN;
          let argument = add_comments (assignment (with_no_in false env)) ~leading:leading_arg in
          Expect.token env T_RPAREN;
          let trailing = Eat.trailing_comments env in
          Expression.Import
            {
              Expression.Import.argument;
              comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing ();
            })
      env

  and call_cover ?(allow_optional_chain = true) ?(in_optional_chain = false) env start_loc left =
    let left = member_cover ~allow_optional_chain ~in_optional_chain env start_loc left in
    let left_to_callee env =
      let { remove_trailing; _ } = trailing_and_remover env in
      remove_trailing (as_expression env left) (fun remover left -> remover#expression left)
    in
    let optional =
      match last_token env with
      | Some T_PLING_PERIOD -> Some Expression.OptionalCall.Optional
      | Some T_NOT when in_optional_chain && (parse_options env).assert_operator ->
        Some Expression.OptionalCall.AssertNonnull
      | _ when in_optional_chain -> Some Expression.OptionalCall.NonOptional
      | _ -> None
    in
    let arguments ?targs env callee =
      let (args_loc, arguments) = arguments env in
      let loc = Loc.btwn start_loc args_loc in
      let call =
        { Expression.Call.callee; targs; arguments = (args_loc, arguments); comments = None }
      in
      let call =
        match optional with
        | Some optional ->
          let open Expression in
          OptionalCall { OptionalCall.call; optional; filtered_out = loc }
        | None -> Expression.Call call
      in
      let in_optional_chain = Option.is_some optional in
      call_cover ~allow_optional_chain ~in_optional_chain env start_loc (Cover_expr (loc, call))
    in
    if no_call env then
      left
    else
      match Peek.token env with
      | T_LPAREN -> arguments env (left_to_callee env)
      | T_LSHIFT
      | T_LESS_THAN
        when should_parse_types env ->
        (* If we are parsing types, then f<T>(e) is a function call with a
           type application. If we aren't, it's a nested binary expression. *)
        let error_callback _ _ = raise Try.Rollback in
        let env = env |> with_error_callback error_callback in
        (* Parameterized call syntax is ambiguous, so we fall back to
           standard parsing if it fails. *)
        Try.or_else env ~fallback:left (fun env ->
            let callee = left_to_callee env in
            let targs = call_type_args env in
            arguments ?targs env callee
        )
      | _ -> left

  and call ?(allow_optional_chain = true) env start_loc left =
    as_expression env (call_cover ~allow_optional_chain env start_loc (Cover_expr left))

  and new_expression env =
    with_loc
      (fun env ->
        let start_loc = Peek.loc env in
        let leading = Peek.comments env in
        Expect.token env T_NEW;

        if in_function env && Peek.token env = T_PERIOD then (
          let trailing = Eat.trailing_comments env in
          Eat.token env;
          let meta =
            Flow_ast_utils.ident_of_source
              (start_loc, "new")
              ?comments:(Flow_ast_utils.mk_comments_opt ~leading ~trailing ())
          in
          match Peek.token env with
          | T_IDENTIFIER { raw = "target"; _ } ->
            let property = Parse.identifier env in
            Expression.(MetaProperty MetaProperty.{ meta; property; comments = None })
          | _ ->
            error_unexpected ~expected:"the identifier `target`" env;
            Eat.token env;

            (* skip unknown identifier *)
            Expression.Identifier meta
          (* return `new` identifier *)
        ) else
          let callee_loc = Peek.loc env in
          let expr =
            match Peek.token env with
            | T_NEW -> new_expression env
            | T_SUPER -> super (env |> with_no_call true)
            | _ when Peek.is_function env -> _function env
            | _ -> primary env
          in
          let callee =
            member ~allow_optional_chain:false (env |> with_no_call true) callee_loc expr
          in
          (* You can do something like
           *   new raw`42`
           *)
          let callee =
            let callee =
              match Peek.token env with
              | T_TEMPLATE_PART part -> tagged_template env callee_loc callee part
              | _ -> callee
            in
            (* Remove trailing comments if the callee is followed by args or type args *)
            if Peek.token env = T_LPAREN || (should_parse_types env && Peek.token env = T_LESS_THAN)
            then
              let { remove_trailing; _ } = trailing_and_remover env in
              remove_trailing callee (fun remover callee -> remover#expression callee)
            else
              callee
          in
          let targs =
            (* If we are parsing types, then new C<T>(e) is a constructor with a
               type application. If we aren't, it's a nested binary expression. *)
            if should_parse_types env then
              (* Parameterized call syntax is ambiguous, so we fall back to
                 standard parsing if it fails. *)
              let error_callback _ _ = raise Try.Rollback in
              let env = env |> with_error_callback error_callback in
              Try.or_else env ~fallback:None call_type_args
            else
              None
          in
          let arguments =
            match Peek.token env with
            | T_LPAREN -> Some (arguments env)
            | _ -> None
          in
          let comments = Flow_ast_utils.mk_comments_opt ~leading () in
          Expression.(New New.{ callee; targs; arguments; comments }))
      env

  and call_type_args =
    let args =
      let rec args_helper env acc =
        match Peek.token env with
        | T_EOF
        | T_GREATER_THAN ->
          List.rev acc
        | _ ->
          let t =
            match Peek.token env with
            | T_IDENTIFIER { value = "_"; _ } ->
              let loc = Peek.loc env in
              let leading = Peek.comments env in
              Expect.identifier env "_";
              let trailing = Eat.trailing_comments env in
              Expression.CallTypeArg.Implicit
                ( loc,
                  {
                    Expression.CallTypeArg.Implicit.comments =
                      Flow_ast_utils.mk_comments_opt ~leading ~trailing ();
                  }
                )
            | _ -> Expression.CallTypeArg.Explicit (Type._type env)
          in
          let acc = t :: acc in
          if Peek.token env <> T_GREATER_THAN then Expect.token env T_COMMA;
          args_helper env acc
      in
      fun env ->
        let leading = Peek.comments env in
        Expect.token env T_LESS_THAN;
        let arguments = args_helper env [] in
        let internal = Peek.comments env in
        Expect.token env T_GREATER_THAN;
        let trailing =
          if Peek.token env = T_LPAREN then
            let { trailing; _ } = trailing_and_remover env in
            trailing
          else
            Eat.trailing_comments env
        in
        {
          Expression.CallTypeArgs.arguments;
          comments = Flow_ast_utils.mk_comments_with_internal_opt ~leading ~trailing ~internal ();
        }
    in
    fun env ->
      Eat.push_lex_mode env Lex_mode.TYPE;
      let node =
        if Peek.token env = T_LESS_THAN then
          Some (with_loc args env)
        else
          None
      in
      Eat.pop_lex_mode env;
      node

  and arguments =
    let spread_element env =
      let leading = Peek.comments env in
      Expect.token env T_ELLIPSIS;
      let argument = assignment env in
      Expression.SpreadElement.{ argument; comments = Flow_ast_utils.mk_comments_opt ~leading () }
    in
    let argument env =
      match Peek.token env with
      | T_ELLIPSIS -> Expression.Spread (with_loc spread_element env)
      | _ -> Expression.Expression (assignment env)
    in
    let rec arguments' env acc =
      match Peek.token env with
      | T_EOF
      | T_RPAREN ->
        List.rev acc
      | _ ->
        let acc = argument env :: acc in
        if Peek.token env <> T_RPAREN then Expect.token env T_COMMA;
        arguments' env acc
    in
    fun env ->
      with_loc
        (fun env ->
          let leading = Peek.comments env in
          Expect.token env T_LPAREN;
          let args = arguments' env [] in
          let internal = Peek.comments env in
          Expect.token env T_RPAREN;
          let trailing = Eat.trailing_comments env in
          {
            Expression.ArgList.arguments = args;
            comments = Flow_ast_utils.mk_comments_with_internal_opt ~leading ~trailing ~internal ();
          })
        env

  and member_cover =
    let dynamic ~allow_optional_chain ~optional env start_loc left =
      let expr = Parse.expression (env |> with_no_call false) in
      let last_loc = Peek.loc env in
      Expect.token env T_RBRACKET;
      let trailing = Eat.trailing_comments env in
      let loc = Loc.btwn start_loc last_loc in
      let member =
        {
          Expression.Member._object = as_expression env left;
          property = Expression.Member.PropertyExpression expr;
          comments = Flow_ast_utils.mk_comments_opt ~trailing ();
        }
      in

      let member =
        match optional with
        | Some optional ->
          Expression.OptionalMember
            { Expression.OptionalMember.member; optional; filtered_out = loc }
        | None -> Expression.Member member
      in
      call_cover
        ~allow_optional_chain
        ~in_optional_chain:(Option.is_some optional)
        env
        start_loc
        (Cover_expr (loc, member))
    in
    let static ~allow_optional_chain ~optional env start_loc left =
      let open Expression.Member in
      let (id_loc, property) =
        match Peek.token env with
        | T_POUND ->
          let ((id_loc, { Ast.PrivateName.name; _ }) as id) = private_identifier env in
          add_used_private env name id_loc;
          (id_loc, PropertyPrivateName id)
        | _ ->
          let ((id_loc, _) as id) = identifier_name env in
          (id_loc, PropertyIdentifier id)
      in
      let loc = Loc.btwn start_loc id_loc in
      (* super.PrivateName is a syntax error *)
      begin
        match (left, property) with
        | (Cover_expr (_, Ast.Expression.Super _), PropertyPrivateName _) ->
          error_at env (loc, Parse_error.SuperPrivate)
        | _ -> ()
      end;
      let member =
        Expression.Member.{ _object = as_expression env left; property; comments = None }
      in
      let member =
        match optional with
        | Some optional ->
          Expression.OptionalMember
            { Expression.OptionalMember.member; optional; filtered_out = loc }
        | None -> Expression.Member member
      in
      call_cover
        ~allow_optional_chain
        ~in_optional_chain:(Option.is_some optional)
        env
        start_loc
        (Cover_expr (loc, member))
    in
    fun ?(allow_optional_chain = true) ?(in_optional_chain = false) env start_loc left ->
      let default_optional =
        if in_optional_chain then
          Some Expression.OptionalMember.NonOptional
        else
          None
      in
      let left = assert_operator_cover env ~in_optional_chain start_loc left in
      match Peek.token env with
      | T_PLING_PERIOD ->
        if not allow_optional_chain then error env Parse_error.OptionalChainNew;
        Expect.token env T_PLING_PERIOD;
        begin
          match Peek.token env with
          | T_TEMPLATE_PART _ ->
            error env Parse_error.OptionalChainTemplate;
            left
          | T_LPAREN -> left
          | T_LESS_THAN when should_parse_types env -> left
          | T_LBRACKET ->
            Eat.token env;
            dynamic
              ~allow_optional_chain
              ~optional:(Some Expression.OptionalMember.Optional)
              env
              start_loc
              left
          | _ ->
            static
              ~allow_optional_chain
              ~optional:(Some Expression.OptionalMember.Optional)
              env
              start_loc
              left
        end
      | T_LBRACKET ->
        Eat.token env;
        dynamic ~allow_optional_chain ~optional:default_optional env start_loc left
      | T_PERIOD ->
        Eat.token env;
        static ~allow_optional_chain ~optional:default_optional env start_loc left
      | T_NOT when in_optional_chain && (parse_options env).assert_operator -> begin
        match Peek.ith_token ~i:1 env with
        | T_TEMPLATE_PART _ ->
          error env Parse_error.OptionalChainTemplate;
          Eat.token env;
          left
        | T_LPAREN ->
          Eat.token env;
          left
        | T_LESS_THAN when should_parse_types env ->
          Eat.token env;
          left
        | T_LBRACKET ->
          Eat.token env;
          Eat.token env;
          dynamic
            ~allow_optional_chain
            ~optional:(Some Expression.OptionalMember.AssertNonnull)
            env
            start_loc
            left
        | T_PERIOD ->
          Eat.token env;
          Eat.token env;
          static
            ~allow_optional_chain
            ~optional:(Some Expression.OptionalMember.AssertNonnull)
            env
            start_loc
            left
        | _ -> left
      end
      | T_TEMPLATE_PART part ->
        if in_optional_chain then error env Parse_error.OptionalChainTemplate;
        let expr = tagged_template env start_loc (as_expression env left) part in
        call_cover ~allow_optional_chain:true env start_loc (Cover_expr expr)
      | _ -> left

  and assert_operator_cover env ~in_optional_chain start_loc left =
    match (Peek.token env, Peek.ith_token ~i:1 env) with
    | (T_NOT, ((T_PERIOD | T_LBRACKET | T_LESS_THAN | T_LPAREN) as next))
      when in_optional_chain && (next <> T_LPAREN || should_parse_types env) ->
      left
    | (T_NOT, _) when (parse_options env).assert_operator ->
      let argument = as_expression env left in
      let end_loc = Peek.loc env in
      Eat.token env;
      let trailing = Eat.trailing_comments env in
      let loc = Loc.btwn start_loc end_loc in
      Cover_expr
        ( loc,
          Expression.(
            Unary
              {
                Unary.operator = Unary.Nonnull;
                argument;
                comments = Flow_ast_utils.mk_comments_opt ~trailing ();
              }
          )
        )
    | _ -> left

  and member ?(allow_optional_chain = true) env start_loc left =
    as_expression env (member_cover ~allow_optional_chain env start_loc (Cover_expr left))

  and _function env =
    with_loc
      (fun env ->
        let (async, leading_async) = Declaration.async env in
        let (sig_loc, (id, params, generator, predicate, return, tparams, leading)) =
          with_loc
            (fun env ->
              let leading_function = Peek.comments env in
              Expect.token env T_FUNCTION;
              let (generator, leading_generator) = Declaration.generator env in
              let leading = List.concat [leading_async; leading_function; leading_generator] in
              (* `await` is a keyword in async functions:
                 - proposal-async-iteration/#prod-AsyncGeneratorExpression
                 - #prod-AsyncFunctionExpression *)
              let await = async in
              (* `yield` is a keyword in generator functions:
                 - proposal-async-iteration/#prod-AsyncGeneratorExpression
                 - #prod-GeneratorExpression *)
              let yield = generator in
              let (id, tparams) =
                if Peek.token env = T_LPAREN then
                  (None, None)
                else
                  let id =
                    match Peek.token env with
                    | T_LESS_THAN -> None
                    | _ ->
                      let env = env |> with_allow_await await |> with_allow_yield yield in
                      let id =
                        id_remove_trailing
                          env
                          (Parse.identifier ~restricted_error:Parse_error.StrictFunctionName env)
                      in
                      Some id
                  in
                  let tparams =
                    type_params_remove_trailing
                      env
                      ~kind:Flow_ast_mapper.FunctionTP
                      (Type.type_params env)
                  in
                  (id, tparams)
              in
              (* #sec-function-definitions-static-semantics-early-errors *)
              let env = env |> with_allow_super No_super in
              let params =
                (* await is a keyword if *this* is an async function, OR if it's already
                   a keyword in the current scope (e.g. if this is a non-async function
                   nested in an async function). *)
                let await = await || allow_await env in
                let params = Declaration.function_params ~await ~yield env in
                if Peek.token env = T_COLON then
                  params
                else
                  function_params_remove_trailing env params
              in
              let (return, predicate) = Type.function_return_annotation_and_predicate_opt env in
              let (return, predicate) =
                match predicate with
                | None -> (return_annotation_remove_trailing env return, predicate)
                | Some _ -> (return, predicate_remove_trailing env predicate)
              in
              (id, params, generator, predicate, return, tparams, leading))
            env
        in
        let simple_params = is_simple_parameter_list params in
        let (body, contains_use_strict) =
          Declaration.function_body env ~async ~generator ~expression:true ~simple_params
        in
        Declaration.strict_function_post_check env ~contains_use_strict id params;
        Expression.Function
          {
            Function.id;
            params;
            body;
            generator;
            effect_ = Function.Arbitrary;
            async;
            predicate;
            return;
            tparams;
            sig_loc;
            comments = Flow_ast_utils.mk_comments_opt ~leading ();
          })
      env

  and number env kind raw =
    let value =
      match kind with
      | LEGACY_OCTAL ->
        strict_error env Parse_error.StrictOctalLiteral;
        begin
          try Int64.to_float (Int64.of_string ("0o" ^ raw)) with
          | Failure _ -> failwith ("Invalid legacy octal " ^ raw)
        end
      | LEGACY_NON_OCTAL ->
        strict_error env Parse_error.StrictNonOctalLiteral;
        begin
          try float_of_string raw with
          | Failure _ -> failwith ("Invalid number " ^ raw)
        end
      | BINARY
      | OCTAL -> begin
        try Int64.to_float (Int64.of_string raw) with
        | Failure _ -> failwith ("Invalid binary/octal " ^ raw)
      end
      | NORMAL -> begin
        try float_of_string raw with
        | Failure _ -> failwith ("Invalid number " ^ raw)
      end
    in
    Expect.token env (T_NUMBER { kind; raw });
    value

  and bigint_strip_n raw =
    let size = String.length raw in
    let str =
      if size != 0 && raw.[size - 1] == 'n' then
        String.sub raw 0 (size - 1)
      else
        raw
    in
    str

  and bigint env kind raw =
    let postraw = bigint_strip_n raw in
    let value = Int64.of_string_opt postraw in
    Expect.token env (T_BIGINT { kind; raw });
    value

  and primary_cover env =
    let loc = Peek.loc env in
    let leading = Peek.comments env in
    match Peek.token env with
    | T_THIS ->
      Eat.token env;
      let trailing = Eat.trailing_comments env in
      Cover_expr
        ( loc,
          Expression.This
            { Expression.This.comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing () }
        )
    | T_NUMBER { kind; raw } ->
      let value = number env kind raw in
      let trailing = Eat.trailing_comments env in
      let comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing () in
      Cover_expr (loc, Expression.NumberLiteral { Ast.NumberLiteral.value; raw; comments })
    | T_BIGINT { kind; raw } ->
      let value = bigint env kind raw in
      let trailing = Eat.trailing_comments env in
      let comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing () in
      Cover_expr (loc, Expression.BigIntLiteral { Ast.BigIntLiteral.value; raw; comments })
    | T_STRING (loc, value, raw, octal) ->
      if octal then strict_error env Parse_error.StrictOctalLiteral;
      Eat.token env;
      let trailing = Eat.trailing_comments env in
      let comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing () in
      let expr =
        let opts = parse_options env in
        match opts.module_ref_prefix with
        | Some prefix when String.starts_with ~prefix value ->
          let prefix_len = String.length prefix in
          Expression.ModuleRefLiteral
            {
              Ast.ModuleRefLiteral.value;
              require_loc = loc;
              def_loc_opt = None;
              prefix_len;
              raw;
              comments;
            }
        | _ -> Expression.StringLiteral { Ast.StringLiteral.value; raw; comments }
      in
      Cover_expr (loc, expr)
    | (T_TRUE | T_FALSE) as token ->
      Eat.token env;
      let value = token = T_TRUE in
      let trailing = Eat.trailing_comments env in
      let comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing () in
      Cover_expr (loc, Expression.BooleanLiteral { Ast.BooleanLiteral.value; comments })
    | T_NULL ->
      Eat.token env;
      let trailing = Eat.trailing_comments env in
      let comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing () in
      Cover_expr (loc, Expression.NullLiteral comments)
    | T_LPAREN -> Cover_expr (group env)
    | T_LCURLY ->
      let (loc, obj, errs) = Parse.object_initializer env in
      Cover_patt ((loc, Expression.Object obj), errs)
    | T_LBRACKET ->
      let (loc, (arr, errs)) = with_loc array_initializer env in
      Cover_patt ((loc, Expression.Array arr), errs)
    | T_DIV
    | T_DIV_ASSIGN ->
      Cover_expr (regexp env)
    | T_LESS_THAN ->
      let (loc, expression) =
        match Parse.jsx_element_or_fragment env with
        | (loc, `Element e) -> (loc, Expression.JSXElement e)
        | (loc, `Fragment f) -> (loc, Expression.JSXFragment f)
      in
      Cover_expr (loc, expression)
    | T_TEMPLATE_PART part ->
      let (loc, template) = template_literal env part in
      Cover_expr (loc, Expression.TemplateLiteral template)
    | T_CLASS -> Cover_expr (Parse.class_expression env)
    (* `match (` *)
    | T_MATCH
      when (parse_options env).pattern_matching
           && (not (Peek.ith_is_line_terminator ~i:1 env))
           && Peek.ith_token ~i:1 env = T_LPAREN ->
      let leading = Peek.comments env in
      let match_keyword_loc = Peek.loc env in
      (* Consume `match` as an identifier, in case it's a call expression. *)
      let id = Parse.identifier env in
      (* Allows trailing comma. *)
      let args = arguments env in
      (* `match (<expr>) {` *)
      if (not (Peek.is_line_terminator env)) && Peek.token env = T_LCURLY then
        let arg = Parser_common.reparse_arguments_as_match_argument env args in
        let env = with_in_match_expression true env in
        Cover_expr (match_expression ~match_keyword_loc ~leading ~arg env)
      else
        (* It's actually a call expression of the form `match(...)` *)
        let callee = (match_keyword_loc, Expression.Identifier id) in
        let (args_loc, _) = args in
        let loc = Loc.btwn match_keyword_loc args_loc in
        let comments = Flow_ast_utils.mk_comments_opt ~leading () in
        let call =
          Expression.Call { Expression.Call.callee; targs = None; arguments = args; comments }
        in
        (* Could have a chained call after this. *)
        call_cover
          ~allow_optional_chain:true
          ~in_optional_chain:false
          env
          match_keyword_loc
          (Cover_expr (loc, call))
    | T_IDENTIFIER { raw = "abstract"; _ } when Peek.ith_token ~i:1 env = T_CLASS ->
      Cover_expr (Parse.class_expression env)
    | _ when Peek.is_identifier env ->
      let id = Parse.identifier env in
      Cover_expr (fst id, Expression.Identifier id)
    | t ->
      error_unexpected env;

      (* Let's get rid of the bad token *)
      begin
        match t with
        | T_ERROR _ -> Eat.token env
        | _ -> ()
      end;

      (* Really no idea how to recover from this. I suppose a null
       * expression is as good as anything *)
      let comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing:[] () in
      Cover_expr (loc, Expression.NullLiteral comments)

  and primary env = as_expression env (primary_cover env)

  and match_expression env ~match_keyword_loc ~leading ~arg =
    let case env =
      let leading = Peek.comments env in
      let invalid_prefix_case =
        if Peek.token env = T_CASE then (
          let loc = Peek.loc env in
          Eat.token env;
          Some loc
        ) else
          None
      in
      let pattern = Parse.match_pattern env in
      let guard =
        if Eat.maybe env T_IF then (
          Expect.token env T_LPAREN;
          let test = Parse.expression env in
          Expect.token env T_RPAREN;
          Some test
        ) else
          None
      in
      let invalid_infix_colon =
        if Peek.token env = T_COLON then (
          let loc = Peek.loc env in
          Eat.token env;
          Some loc
        ) else (
          Expect.token env T_ARROW;
          None
        )
      in
      let body = assignment env in
      let invalid_suffix_semicolon =
        match Peek.token env with
        | T_EOF
        | T_RCURLY ->
          None
        | T_SEMICOLON ->
          let loc = Peek.loc env in
          Eat.token env;
          Some loc
        | _ ->
          Expect.token env T_COMMA;
          None
      in
      let trailing = Eat.trailing_comments env in
      let comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing () in
      let invalid_syntax =
        {
          Match.Case.InvalidSyntax.invalid_prefix_case;
          invalid_infix_colon;
          invalid_suffix_semicolon;
        }
      in
      { Match.Case.pattern; body; guard; comments; invalid_syntax }
    in
    let rec case_list env acc =
      match Peek.token env with
      | T_EOF
      | T_RCURLY ->
        List.rev acc
      | _ -> case_list env (with_loc case env :: acc)
    in
    with_loc
      ~start_loc:match_keyword_loc
      (fun env ->
        Expect.token env T_LCURLY;
        let cases = case_list env [] in
        Expect.token env T_RCURLY;
        let trailing = Eat.trailing_comments env in
        Expression.Match
          {
            Match.arg;
            cases;
            match_keyword_loc;
            comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing ();
          })
      env

  and template_literal =
    let rec template_parts env quasis expressions =
      let expr = Parse.expression env in
      let expressions = expr :: expressions in
      match Peek.token env with
      | T_RCURLY ->
        Eat.push_lex_mode env Lex_mode.TEMPLATE;
        let (loc, part, is_tail) =
          match Peek.token env with
          | T_TEMPLATE_PART (loc, cooked, raw, _, tail) ->
            let open Ast.Expression.TemplateLiteral in
            Eat.token env;
            (loc, { Element.value = { Element.cooked; raw }; tail }, tail)
          | _ -> assert false
        in
        Eat.pop_lex_mode env;
        let quasis = (loc, part) :: quasis in
        if is_tail then
          (loc, List.rev quasis, List.rev expressions)
        else
          template_parts env quasis expressions
      | _ ->
        (* Malformed template *)
        error_unexpected ~expected:"a template literal part" env;
        let imaginary_quasi =
          ( fst expr,
            {
              Expression.TemplateLiteral.Element.value =
                { Expression.TemplateLiteral.Element.raw = ""; cooked = "" };
              tail = true;
            }
          )
        in
        (fst expr, List.rev (imaginary_quasi :: quasis), List.rev expressions)
    in
    fun env ((start_loc, cooked, raw, _, is_tail) as part) ->
      let leading = Peek.comments env in
      Expect.token env (T_TEMPLATE_PART part);
      let (end_loc, quasis, expressions) =
        let head =
          ( start_loc,
            {
              Ast.Expression.TemplateLiteral.Element.value =
                { Ast.Expression.TemplateLiteral.Element.cooked; raw };
              tail = is_tail;
            }
          )
        in

        if is_tail then
          (start_loc, [head], [])
        else
          template_parts env [head] []
      in
      let trailing = Eat.trailing_comments env in
      let loc = Loc.btwn start_loc end_loc in
      ( loc,
        {
          Expression.TemplateLiteral.quasis;
          expressions;
          comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing ();
        }
      )

  and tagged_template env start_loc tag part =
    let tag = expression_remove_trailing env tag in
    let quasi = template_literal env part in
    ( Loc.btwn start_loc (fst quasi),
      Expression.(TaggedTemplate TaggedTemplate.{ tag; quasi; comments = None })
    )

  and group env =
    let leading = Peek.comments env in
    let (loc, cover) =
      with_loc
        (fun env ->
          Expect.token env T_LPAREN;
          let expr_start_loc = Peek.loc env in
          let expression = assignment env in
          let ret =
            match Peek.token env with
            | T_COLON ->
              let annot = Type.annotation env in
              Group_typecast Expression.TypeCast.{ expression; annot; comments = None }
            | T_COMMA -> Group_expr (sequence env ~start_loc:expr_start_loc [expression])
            | _ -> Group_expr expression
          in
          Expect.token env T_RPAREN;
          ret)
        env
    in
    let trailing = Eat.trailing_comments env in
    let ret =
      match cover with
      | Group_expr expr -> expr
      | Group_typecast cast -> (loc, Expression.TypeCast cast)
    in
    add_comments ret ~leading ~trailing

  and add_comments ?(leading = []) ?(trailing = []) (loc, expression) =
    let merge_comments inner =
      Flow_ast_utils.merge_comments
        ~inner
        ~outer:(Flow_ast_utils.mk_comments_opt ~leading ~trailing ())
    in
    let merge_comments_with_internal inner =
      Flow_ast_utils.merge_comments_with_internal
        ~inner
        ~outer:(Flow_ast_utils.mk_comments_opt ~leading ~trailing ())
    in
    let open Expression in
    ( loc,
      match expression with
      | Array ({ Array.comments; _ } as e) ->
        Array { e with Array.comments = merge_comments_with_internal comments }
      | ArrowFunction ({ Function.comments; _ } as e) ->
        ArrowFunction { e with Function.comments = merge_comments comments }
      | AsExpression ({ AsExpression.comments; _ } as e) ->
        AsExpression { e with AsExpression.comments = merge_comments comments }
      | AsConstExpression ({ AsConstExpression.comments; _ } as e) ->
        AsConstExpression { e with AsConstExpression.comments = merge_comments comments }
      | Assignment ({ Assignment.comments; _ } as e) ->
        Assignment { e with Assignment.comments = merge_comments comments }
      | Binary ({ Binary.comments; _ } as e) ->
        Binary { e with Binary.comments = merge_comments comments }
      | Call ({ Call.comments; _ } as e) -> Call { e with Call.comments = merge_comments comments }
      | Class ({ Class.comments; _ } as e) ->
        Class { e with Class.comments = merge_comments comments }
      | Conditional ({ Conditional.comments; _ } as e) ->
        Conditional { e with Conditional.comments = merge_comments comments }
      | Function ({ Function.comments; _ } as e) ->
        Function { e with Function.comments = merge_comments comments }
      | Identifier (loc, ({ Identifier.comments; _ } as e)) ->
        Identifier (loc, { e with Identifier.comments = merge_comments comments })
      | Import ({ Import.comments; _ } as e) ->
        Import { e with Import.comments = merge_comments comments }
      | JSXElement ({ JSX.comments; _ } as e) ->
        JSXElement { e with JSX.comments = merge_comments comments }
      | JSXFragment ({ JSX.frag_comments; _ } as e) ->
        JSXFragment { e with JSX.frag_comments = merge_comments frag_comments }
      | StringLiteral ({ StringLiteral.comments; _ } as e) ->
        StringLiteral { e with StringLiteral.comments = merge_comments comments }
      | BooleanLiteral ({ BooleanLiteral.comments; _ } as e) ->
        BooleanLiteral { e with BooleanLiteral.comments = merge_comments comments }
      | NullLiteral comments -> NullLiteral (merge_comments comments)
      | NumberLiteral ({ NumberLiteral.comments; _ } as e) ->
        NumberLiteral { e with NumberLiteral.comments = merge_comments comments }
      | BigIntLiteral ({ BigIntLiteral.comments; _ } as e) ->
        BigIntLiteral { e with BigIntLiteral.comments = merge_comments comments }
      | RegExpLiteral ({ RegExpLiteral.comments; _ } as e) ->
        RegExpLiteral { e with RegExpLiteral.comments = merge_comments comments }
      | Match ({ Match.comments; _ } as e) ->
        Match { e with Match.comments = merge_comments comments }
      | ModuleRefLiteral ({ ModuleRefLiteral.comments; _ } as e) ->
        ModuleRefLiteral { e with ModuleRefLiteral.comments = merge_comments comments }
      | Logical ({ Logical.comments; _ } as e) ->
        Logical { e with Logical.comments = merge_comments comments }
      | Member ({ Member.comments; _ } as e) ->
        Member { e with Member.comments = merge_comments comments }
      | MetaProperty ({ MetaProperty.comments; _ } as e) ->
        MetaProperty { e with MetaProperty.comments = merge_comments comments }
      | New ({ New.comments; _ } as e) -> New { e with New.comments = merge_comments comments }
      | Object ({ Object.comments; _ } as e) ->
        Object { e with Object.comments = merge_comments_with_internal comments }
      | OptionalCall ({ OptionalCall.call = { Call.comments; _ } as call; _ } as optional_call) ->
        OptionalCall
          {
            optional_call with
            OptionalCall.call = { call with Call.comments = merge_comments comments };
          }
      | OptionalMember
          ({ OptionalMember.member = { Member.comments; _ } as member; _ } as optional_member) ->
        OptionalMember
          {
            optional_member with
            OptionalMember.member = { member with Member.comments = merge_comments comments };
          }
      | Sequence ({ Sequence.comments; _ } as e) ->
        Sequence { e with Sequence.comments = merge_comments comments }
      | Super { Super.comments; _ } -> Super { Super.comments = merge_comments comments }
      | TaggedTemplate ({ TaggedTemplate.comments; _ } as e) ->
        TaggedTemplate { e with TaggedTemplate.comments = merge_comments comments }
      | TemplateLiteral ({ TemplateLiteral.comments; _ } as e) ->
        TemplateLiteral { e with TemplateLiteral.comments = merge_comments comments }
      | This { This.comments; _ } -> This { This.comments = merge_comments comments }
      | TSSatisfies ({ TSSatisfies.comments; _ } as e) ->
        TSSatisfies { e with TSSatisfies.comments = merge_comments comments }
      | TypeCast ({ TypeCast.comments; _ } as e) ->
        TypeCast { e with TypeCast.comments = merge_comments comments }
      | Unary ({ Unary.comments; _ } as e) ->
        Unary { e with Unary.comments = merge_comments comments }
      | Update ({ Update.comments; _ } as e) ->
        Update { e with Update.comments = merge_comments comments }
      | Yield ({ Yield.comments; _ } as e) ->
        Yield { e with Yield.comments = merge_comments comments }
    )

  and array_initializer =
    let rec elements env (acc, errs) =
      match Peek.token env with
      | T_EOF
      | T_RBRACKET ->
        (List.rev acc, Pattern_cover.rev_errors errs)
      | T_COMMA ->
        let loc = Peek.loc env in
        Eat.token env;
        elements env (Expression.Array.Hole loc :: acc, errs)
      | T_ELLIPSIS ->
        let leading = Peek.comments env in
        let (loc, (argument, new_errs)) =
          with_loc
            (fun env ->
              Eat.token env;
              match assignment_cover env with
              | Cover_expr argument -> (argument, Pattern_cover.empty_errors)
              | Cover_patt (argument, new_errs) -> (argument, new_errs))
            env
        in
        let elem =
          Expression.(
            Array.Spread
              ( loc,
                SpreadElement.{ argument; comments = Flow_ast_utils.mk_comments_opt ~leading () }
              )
          )
        in
        let is_last = Peek.token env = T_RBRACKET in
        (* if this array is interpreted as a pattern, the spread becomes an AssignmentRestElement
           which must be the last element. We can easily error about additional elements since
           they will be in the element list, but a trailing elision, like `[...x,]`, is not part
           of the AST. so, keep track of the error so we can raise it if this is a pattern. *)
        let new_errs =
          if (not is_last) && Peek.ith_token ~i:1 env = T_RBRACKET then
            let if_patt = (loc, Parse_error.ElementAfterRestElement) :: new_errs.if_patt in
            { new_errs with if_patt }
          else
            new_errs
        in
        if not is_last then Expect.token env T_COMMA;
        let acc = elem :: acc in
        let errs = Pattern_cover.rev_append_errors new_errs errs in
        elements env (acc, errs)
      | _ ->
        let (elem, new_errs) =
          match assignment_cover env with
          | Cover_expr elem -> (elem, Pattern_cover.empty_errors)
          | Cover_patt (elem, new_errs) -> (elem, new_errs)
        in
        if Peek.token env <> T_RBRACKET then Expect.token env T_COMMA;
        let acc = Expression.Array.Expression elem :: acc in
        let errs = Pattern_cover.rev_append_errors new_errs errs in
        elements env (acc, errs)
    in
    fun env ->
      let leading = Peek.comments env in
      Expect.token env T_LBRACKET;
      let (elems, errs) = elements env ([], Pattern_cover.empty_errors) in
      let internal = Peek.comments env in
      Expect.token env T_RBRACKET;
      let trailing = Eat.trailing_comments env in
      ( {
          Ast.Expression.Array.elements = elems;
          comments = Flow_ast_utils.mk_comments_with_internal_opt ~leading ~trailing ~internal ();
        },
        errs
      )

  and regexp env =
    Eat.push_lex_mode env Lex_mode.REGEXP;
    let loc = Peek.loc env in
    let leading = Peek.comments env in
    let tkn = Peek.token env in
    let (raw, pattern, raw_flags, trailing) =
      match tkn with
      | T_REGEXP (_, pattern, flags) ->
        Eat.token env;
        let trailing = Eat.trailing_comments env in
        let raw = "/" ^ pattern ^ "/" ^ flags in
        (raw, pattern, flags, trailing)
      | _ ->
        error_unexpected ~expected:"a regular expression" env;
        ("", "", "", [])
    in
    Eat.pop_lex_mode env;
    let filtered_flags = Buffer.create (String.length raw_flags) in
    String.iter
      (function
        | ('d' | 'g' | 'i' | 'm' | 's' | 'u' | 'y' | 'v') as c -> Buffer.add_char filtered_flags c
        | _ -> ())
      raw_flags;
    let flags = Buffer.contents filtered_flags in
    if flags <> raw_flags then error env (Parse_error.InvalidRegExpFlags raw_flags);
    let comments = Flow_ast_utils.mk_comments_opt ~leading ~trailing () in
    (loc, Expression.RegExpLiteral { Ast.RegExpLiteral.pattern; flags; raw; comments })

  and try_arrow_function =
    (* Certain errors (almost all errors) cause a rollback *)
    let error_callback _ =
      Parse_error.(
        function
        (* Don't rollback on these errors. *)
        | StrictParamDupe
        | StrictParamName
        | StrictReservedWord
        | ParameterAfterRestParameter
        | NewlineBeforeArrow
        | AwaitAsIdentifierReference
        | AwaitInAsyncFormalParameters
        | YieldInFormalParameters
        | ThisParamBannedInArrowFunctions ->
          ()
        (* Everything else causes a rollback *)
        | _ -> raise Try.Rollback
      )
    in
    let concise_function_body env =
      match Peek.token env with
      | T_LCURLY ->
        let (body_block, contains_use_strict) = Parse.function_block_body env ~expression:true in
        (Function.BodyBlock body_block, contains_use_strict)
      | _ ->
        let expr = Parse.assignment env in
        (Function.BodyExpression expr, false)
    in
    fun env ->
      let env = env |> with_error_callback error_callback in
      let start_loc = Peek.loc env in
      (* a T_ASYNC could either be a parameter name or it could be indicating
       * that it's an async function *)
      let (async, leading) =
        if Peek.ith_token ~i:1 env <> T_ARROW then
          Declaration.async env
        else
          (false, [])
      in

      (* await is a keyword if this is an async function, or if we're in one already. *)
      let await = async || allow_await env in
      let env = with_allow_await await env in

      let yield = allow_yield env in

      let (sig_loc, (tparams, params, return, predicate)) =
        with_loc
          (fun env ->
            let tparams =
              type_params_remove_trailing env ~kind:Flow_ast_mapper.FunctionTP (Type.type_params env)
            in
            (* Disallow all fancy features for identifier => body *)
            if Peek.is_identifier env && tparams = None then
              let ((loc, _) as name) =
                Parse.identifier ~restricted_error:Parse_error.StrictParamName env
              in
              let param =
                ( loc,
                  {
                    Ast.Function.Param.argument =
                      ( loc,
                        Pattern.Identifier
                          {
                            Pattern.Identifier.name;
                            annot = Ast.Type.Missing (Peek.loc_skip_lookahead env);
                            optional = false;
                          }
                      );
                    default = None;
                  }
                )
              in
              ( tparams,
                ( loc,
                  {
                    Ast.Function.Params.params = [param];
                    rest = None;
                    comments = None;
                    this_ = None;
                  }
                ),
                Ast.Function.ReturnAnnot.Missing Loc.{ loc with start = loc._end },
                None
              )
            else
              let params = Declaration.function_params ~await ~yield env in

              (* https://tc39.es/ecma262/#prod-ArrowFormalParameters *)
              Declaration.check_unique_formal_parameters env params;

              (* There's an ambiguity if you use a function type as the return
               * type for an arrow function. So we disallow anonymous function
               * types in arrow function return types unless the function type is
               * enclosed in parens *)
              let (return, predicate) =
                env
                |> with_no_anon_function_type true
                |> Type.function_return_annotation_and_predicate_opt
              in
              (tparams, params, return, predicate))
          env
      in
      (* It's hard to tell if an invalid expression was intended to be an
       * arrow function before we see the =>. If there are no params, that
       * implies "()" which is only ever found in arrow params. Similarly,
       * rest params indicate arrow functions. Therefore, if we see a rest
       * param or an empty param list then we can disable the rollback and
       * instead generate errors as if we were parsing an arrow function *)
      let env =
        match params with
        | (_, { Ast.Function.Params.params = _; rest = Some _; this_ = None; comments = _ })
        | (_, { Ast.Function.Params.params = []; rest = _; this_ = None; comments = _ }) ->
          without_error_callback env
        | _ -> env
      in

      (* Disallow this param annotations in arrow functions *)
      let params =
        match params with
        | (loc, ({ Ast.Function.Params.this_ = Some (this_loc, _); _ } as params)) ->
          error_at env (this_loc, Parse_error.ThisParamBannedInArrowFunctions);
          (loc, { params with Ast.Function.Params.this_ = None })
        | _ -> params
      in
      let simple_params = is_simple_parameter_list params in

      if Peek.is_line_terminator env && Peek.token env = T_ARROW then
        error env Parse_error.NewlineBeforeArrow;
      Expect.token env T_ARROW;

      (* Now we know for sure this is an arrow function *)
      let env = without_error_callback env in
      (* arrow functions can't be generators *)
      let env = enter_function env ~async ~generator:false ~simple_params in
      let (end_loc, (body, contains_use_strict)) = with_loc concise_function_body env in
      Declaration.strict_function_post_check env ~contains_use_strict None params;
      let loc = Loc.btwn start_loc end_loc in
      Cover_expr
        ( loc,
          let open Expression in
          ArrowFunction
            {
              Function.id = None;
              params;
              body;
              async;
              generator = false;
              (* arrow functions cannot be generators *)
              effect_ = Function.Arbitrary;
              predicate;
              return;
              tparams;
              sig_loc;
              comments = Flow_ast_utils.mk_comments_opt ~leading ();
            }
        )

  and sequence =
    let rec helper acc env =
      match Peek.token env with
      | T_COMMA ->
        Eat.token env;
        let expr = assignment env in
        helper (expr :: acc) env
      | _ ->
        let expressions = List.rev acc in
        Expression.(Sequence Sequence.{ expressions; comments = None })
    in
    (fun env ~start_loc acc -> with_loc ~start_loc (helper acc) env)
end
