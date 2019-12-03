%% Copyright (c) Facebook, Inc. and its affiliates.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
-module(erlfmt_format).

-export([expr_to_algebra/1]).

-import(erlfmt_algebra, [
    document_text/1,
    document_spaces/1,
    document_combine/2,
    document_flush/1,
    document_choice/2,
    document_single_line/1,
    document_reduce/2
]).

-import(erl_anno, [text/1]).

-define(IN_RANGE(Value, Low, High), (Value) >= (Low) andalso (Value) =< (High)).
-define(IS_OCT_DIGIT(C), ?IN_RANGE(C, $0, $7)).

%% Thses operators when mixed, force parens on nested operators
-define(MIXED_REQUIRE_PARENS_OPS, ['or', 'and', 'andalso', 'orelse']).

%% These operators always force parens on nested operators
-define(REQUIRE_PARENS_OPS, ['bor', 'band', 'bxor', 'bsl', 'bsr', '++', '--']).

-spec expr_to_algebra(erlfmt_parse:abstract_form()) -> erlfmt_algebra:document().
expr_to_algebra({integer, Meta, _Value}) ->
    document_text(format_integer(text(Meta)));
expr_to_algebra({float, Meta, _Value}) ->
    document_text(format_float(text(Meta)));
expr_to_algebra({char, Meta, Value}) ->
    document_text(format_char(text(Meta), Value));
expr_to_algebra({atom, Meta, Value}) ->
    document_text(format_atom(text(Meta), Value));
expr_to_algebra({string, Meta, Value}) ->
    document_text(format_string(text(Meta), Value));
expr_to_algebra({var, Meta, _Value}) ->
    document_text(text(Meta));
expr_to_algebra({concat, _Meta, Values0}) ->
    Values = lists:map(fun expr_to_algebra/1, Values0),
    Horizontal = document_reduce(fun combine_space/2, Values),
    Vertical = document_reduce(fun combine_newline/2, Values),
    document_choice(Horizontal, Vertical);
expr_to_algebra({op, _Meta, Op, Expr}) ->
    unary_op_to_algebra(Op, Expr);
expr_to_algebra({op, _Meta, Op, Left, Right}) ->
    binary_op_to_algebra(Op, Left, Right);
expr_to_algebra({tuple, _Meta, Values}) ->
    container_to_algebra(Values, "{", "}");
expr_to_algebra({list, _Meta, Values}) ->
    container_to_algebra(Values, "[", "]");
expr_to_algebra({cons, _, Head, Tail}) ->
    cons_to_algebra(Head, Tail);
expr_to_algebra({bin, _Meta, Values}) ->
    container_to_algebra(Values, "<<", ">>");
expr_to_algebra({bin_element, _Meta, Expr, Size, Types}) ->
    bin_element_to_algebra(Expr, Size, Types).

combine_space(D1, D2) -> combine_sep(D1, " ", D2).

combine_comma_space(D1, D2) -> combine_sep(D1, ", ", D2).

combine_dash(D1, D2) -> combine_sep(D1, "-", D2).

combine_sep(D1, Sep, D2) ->
    document_combine(D1, document_combine(document_text(Sep), D2)).

combine_newline(D1, D2) ->
    document_combine(document_flush(D1), D2).

combine_comma_newline(D1, D2) ->
    document_combine(document_flush(document_combine(D1, document_text(","))), D2).

wrap(Left, Doc, Right) ->
    document_combine(document_text(Left), document_combine(Doc, document_text(Right))).

wrap_in_parens(Doc) -> wrap("(", Doc, ")").

wrap_nested(Left, Doc, Right) ->
    Nested = document_combine(document_spaces(4), Doc),
    combine_newline(document_text(Left), combine_newline(Nested, document_text(Right))).

%% TODO: handle underscores once on OTP 23
format_integer([B1, B2, $# | Digits]) -> [B1, B2, $# | string:uppercase(Digits)];
format_integer(Other) -> Other.

%% TODO: handle underscores in int part on OTP 23
format_float(FloatText) ->
    [IntPart, DecimalPart] = string:split(FloatText, "."),
    [IntPart, "." | string:lowercase(DecimalPart)].

format_char("$ ", $\s) -> "$\\s";
format_char("$\\s", $\s) -> "$\\s";
format_char([$$ | String], Value) ->
    [$$ | escape_string_loop(String, [Value], -1)].

format_atom(Text, Atom) ->
    RawString = atom_to_list(Atom),
    case erl_scan:reserved_word(Atom) orelse atom_needs_quotes(RawString) of
        true -> escape_string(Text, RawString, $');
        false -> RawString
    end.

format_string(String, Original) ->
    escape_string(String, Original, $").

unary_op_to_algebra(Op, Expr) ->
    OpD = document_text(atom_to_binary(Op, utf8)),
    ExprD = unary_operand_to_algebra(Op, Expr),
    if
        Op =:= 'not'; Op =:= 'bnot'; Op =:= 'catch' ->
            combine_space(OpD, ExprD);
        true ->
            document_combine(OpD, ExprD)
    end.

binary_op_to_algebra(Op, Left, Right) ->
    binary_op_to_algebra(Op, Left, Right, 4, erl_parse:inop_prec(Op)).

binary_op_to_algebra(Op, Left, Right, Indent, {PrecL, _, PrecR}) ->
    OpD = document_text(atom_to_binary(Op, utf8)),
    %% Propagate indent for left-associative operators,
    %% for right-associative ones document algebra does it for us
    LeftD = binary_operand_to_algebra(Op, Left, Indent, PrecL),
    RightD = binary_operand_to_algebra(Op, Right, 0, PrecR),
    LeftOpD = combine_space(LeftD, OpD),

    document_choice(
        combine_space(LeftOpD, document_single_line(RightD)),
        combine_newline(LeftOpD, document_combine(document_spaces(Indent), RightD))
    ).

%% not and bnot are nestable without parens, others are not
unary_operand_to_algebra(Op, {op, _, Op, Expr}) when Op =:= 'not'; Op =:= 'bnot' ->
    unary_op_to_algebra(Op, Expr);
unary_operand_to_algebra(_, {op, _, Op, Expr}) ->
    wrap_in_parens(unary_op_to_algebra(Op, Expr));
unary_operand_to_algebra(_, {op, _, Op, Left, Right}) ->
    wrap_in_parens(binary_op_to_algebra(Op, Left, Right));
unary_operand_to_algebra(_, Expr) ->
    expr_to_algebra(Expr).

binary_operand_to_algebra(_ParentOp, {op, _, 'catch', Expr}, _Indent, _Prec) ->
    wrap_in_parens(unary_op_to_algebra('catch', Expr));
binary_operand_to_algebra(_ParentOp, {op, _, Op, Expr}, _Indent, _Prec) ->
    unary_op_to_algebra(Op, Expr);
binary_operand_to_algebra(ParentOp, {op, _, ParentOp, Left, Right}, Indent, Prec) ->
    %% Same operator on correct side - no parens and no repeated nesting
    case erl_parse:inop_prec(ParentOp) of
        {Prec, Prec, _} = Precs ->
            binary_op_to_algebra(ParentOp, Left, Right, Indent, Precs);
        {_, Prec, Prec} = Precs ->
            binary_op_to_algebra(ParentOp, Left, Right, Indent, Precs);
        Precs ->
            wrap_in_parens(binary_op_to_algebra(ParentOp, Left, Right, 4, Precs))
    end;
binary_operand_to_algebra(ParentOp, {op, _, Op, Left, Right}, _Indent, Prec) ->
    {_, NestedPrec, _} = Precs = erl_parse:inop_prec(Op),
    NeedsParens =
        lists:member(ParentOp, ?REQUIRE_PARENS_OPS) orelse
        (lists:member(ParentOp, ?MIXED_REQUIRE_PARENS_OPS) andalso
            lists:member(Op, ?MIXED_REQUIRE_PARENS_OPS)) orelse
        NestedPrec < Prec,

    case NeedsParens of
        true -> wrap_in_parens(binary_op_to_algebra(Op, Left, Right, 4, Precs));
        false -> binary_op_to_algebra(Op, Left, Right, 4, Precs)
    end;
binary_operand_to_algebra(_ParentOp, Expr, _Indent, _Prec) ->
    expr_to_algebra(Expr).

container_to_algebra([], Left, Right) -> document_text([Left | Right]);
container_to_algebra(Values0, Left, Right) ->
    Values = lists:map(fun expr_to_algebra/1, Values0),
    SingleLine = lists:map(fun erlfmt_algebra:document_single_line/1, Values),

    Horizontal = document_reduce(fun combine_comma_space/2, SingleLine),
    Vertical = document_reduce(fun combine_comma_newline/2, Values),

    document_choice(
        wrap(Left, Horizontal, Right),
        wrap_nested(Left, Vertical, Right)
    ).

cons_to_algebra(Head, Tail) ->
    HeadD = expr_to_algebra(Head),
    TailD = document_combine(document_text("| "), expr_to_algebra(Tail)),

    document_choice(
        combine_space(document_single_line(HeadD), document_single_line(TailD)),
        combine_newline(HeadD, TailD)
    ).

bin_element_to_algebra(Expr, Size, Types) ->
    Docs =
        [bin_expr_to_algebra(Expr)] ++
        [bin_size_to_algebra(Size) || Size =/= default] ++
        [bin_types_to_algebra(Types) || Types =/= default],
    document_reduce(fun erlfmt_algebra:document_combine/2, Docs).

bin_expr_to_algebra({op, _, Op, Expr}) when Op =/= 'catch' -> unary_op_to_algebra(Op, Expr);
bin_expr_to_algebra(Expr) -> expr_max_to_algebra(Expr).

bin_size_to_algebra(Expr) ->
    document_combine(document_text(":"), expr_max_to_algebra(Expr)).

bin_types_to_algebra(Types) ->
    TypesD = lists:map(fun bin_type_to_algebra/1, Types),
    document_combine(document_text("/"), document_reduce(fun combine_dash/2, TypesD)).

bin_type_to_algebra({Type, Size}) ->
    combine_sep(expr_to_algebra(Type), ":", expr_to_algebra(Size));
bin_type_to_algebra(Type) ->
    expr_to_algebra(Type).

expr_max_to_algebra({op, _, Op, Expr}) ->
    wrap_in_parens(unary_op_to_algebra(Op, Expr));
expr_max_to_algebra({op, _, Op, Left, Right}) ->
    wrap_in_parens(binary_op_to_algebra(Op, Left, Right));
%% TODO: map, calls & records also get wrapped in parens
expr_max_to_algebra(Expr) ->
    expr_to_algebra(Expr).

atom_needs_quotes([C0 | Cs]) when C0 >= $a, C0 =< $z ->
    lists:any(fun
        (C) when ?IN_RANGE(C, $a, $z); ?IN_RANGE(C, $A, $Z); ?IN_RANGE(C, $0, $9); C =:= $_; C=:= $@ -> false;
        (_) -> true
    end, Cs);
atom_needs_quotes(_) -> true.

escape_string([Quote | Rest], Original, Quote) ->
    [Quote | escape_string_loop(Rest, Original, Quote)].

%% Remove unneeded escapes, upcase hex escapes
escape_string_loop(Tail, [], _Quote) -> Tail;
escape_string_loop([$\\, $x | EscapeAndRest], [_Escaped | Original], Quote) ->
    {Escape, Rest} = escape_hex(EscapeAndRest),
    [$\\, $x, Escape | escape_string_loop(Rest, Original, Quote)];
escape_string_loop([$\\, Escape | Rest], [Value | Original], Quote) ->
    if
        ?IS_OCT_DIGIT(Escape) ->
            case Rest of
                [D2, D3 | Rest1] when ?IS_OCT_DIGIT(D2), ?IS_OCT_DIGIT(D3) ->
                    [$\\, Escape, D2, D3 | escape_string_loop(Rest1, Original, Quote)];
                [D2 | Rest1] when ?IS_OCT_DIGIT(D2) ->
                    [$\\, Escape, D2 | escape_string_loop(Rest1, Original, Quote)];
                _ ->
                    [$\\, Escape | escape_string_loop(Rest, Original, Quote)]
            end;
        Escape =:= $s ->
            [Value | escape_string_loop(Rest, Original, Quote)];
        Escape =:= Quote; Escape =:= $\\; Escape =/= Value ->
            [$\\, Escape | escape_string_loop(Rest, Original, Quote)];
        true ->
            [Escape | escape_string_loop(Rest, Original, Quote)]
    end;
escape_string_loop([C | Rest], [C | Original], Quote) ->
    [C | escape_string_loop(Rest, Original, Quote)].

escape_hex([${ | Rest0]) ->
    [Escape, Rest] = string:split(Rest0, "}"),
    {[${, string:uppercase(Escape), $}], Rest};
escape_hex([X1, X2 | Rest]) ->
    {string:uppercase([X1, X2]), Rest}.
