(**
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)
module Token = Full_fidelity_minimal_token
module Syntax = Full_fidelity_minimal_syntax
module SyntaxKind = Full_fidelity_syntax_kind
module TokenKind = Full_fidelity_token_kind
module SyntaxError = Full_fidelity_syntax_error

module type ParserType = sig
  module Lexer : Full_fidelity_lexer_sig.Lexer_S
  type t
  val errors : t -> SyntaxError.t list
  val with_errors : t -> SyntaxError.t list -> t
  val lexer : t -> Lexer.t
  val with_lexer : t -> Lexer.t -> t
end

module WithParser(Parser : ParserType) = struct

  let next_token parser =
    let lexer = Parser.lexer parser in
    let (lexer, token) = Parser.Lexer.next_token lexer in
    let parser = Parser.with_lexer parser lexer in
    (parser, token)

  let peek_token ?(lookahead=0) parser =
    let rec lex_ahead lexer n =
      let (next_lexer, token) = Parser.Lexer.next_token lexer in
      match n with
      | 0 -> token
      | _ -> lex_ahead next_lexer (n-1)
    in
      lex_ahead (Parser.lexer parser) lookahead

  let next_token_as_name parser =
    (* TODO: This isn't right.  Pass flags to the lexer. *)
    let lexer = Parser.lexer parser in
    let (lexer, token) = Parser.Lexer.next_token_as_name lexer in
    let parser = Parser.with_lexer parser lexer in
    (parser, token)

  let peek_token_kind parser =
    Token.kind (peek_token parser)

  let skip_token parser =
    let (parser, _) = next_token parser in
    parser

  let with_error parser message =
    (* TODO: Should be able to express errors on whole syntax node. *)
    (* TODO: Is this even right? Won't this put the error on the trivia? *)
    let lexer = Parser.lexer parser in
    let start_offset = Parser.Lexer.start_offset lexer in
    let end_offset = Parser.Lexer.end_offset lexer in
    let error = SyntaxError.make start_offset end_offset message in
    let errors = Parser.errors parser in
    Parser.with_errors parser (error :: errors)

  let expect_token parser kind error =
    let (parser1, token) = next_token parser in
    if (Token.kind token) = kind then
      (parser1, Syntax.make_token token)
    else
      (* ERROR RECOVERY: Create a missing token for the expected token,
         and continue on from the current token. Don't skip it. *)
      (with_error parser error, (Syntax.make_missing()))

  let expect_name parser =
    (* TODO: What if the name is a keyword? *)
    expect_token parser TokenKind.Name SyntaxError.error1004

  let expect_class_name parser =
    if peek_token_kind parser = TokenKind.Colon then
      let lexer = Parser.lexer parser in
      let (lexer, token) = Parser.Lexer.next_xhp_class_name lexer in
      let parser = Parser.with_lexer parser lexer in
      (parser, (Syntax.make_token token))
    else
      expect_name parser

  (* We accept either a Name or a QualifiedName token when looking for a
     qualified name. *)
  let expect_qualified_name parser =
    (* TODO: What if the name is a keyword? *)
    let (parser1, name) = next_token parser in
    match Token.kind name with
    | TokenKind.QualifiedName
    | TokenKind.Name -> (parser1, Syntax.make_token name)
    | _ ->
      (with_error parser SyntaxError.error1004, (Syntax.make_missing()))

  let expect_function parser =
    expect_token parser TokenKind.Function SyntaxError.error1003

  let expect_variable parser =
    expect_token parser TokenKind.Variable SyntaxError.error1008

  let expect_semicolon parser =
    expect_token parser TokenKind.Semicolon SyntaxError.error1010

  let expect_colon parser =
    expect_token parser TokenKind.Colon SyntaxError.error1020

  let expect_left_brace parser =
    expect_token parser TokenKind.LeftBrace SyntaxError.error1034

  let expect_right_brace parser =
    expect_token parser TokenKind.RightBrace SyntaxError.error1006

  let expect_left_paren parser =
    expect_token parser TokenKind.LeftParen SyntaxError.error1019

  let expect_right_paren parser =
    expect_token parser TokenKind.RightParen SyntaxError.error1011

  let expect_left_angle parser =
    expect_token parser TokenKind.LessThan SyntaxError.error1021

  let expect_right_angle parser =
    expect_token parser TokenKind.GreaterThan SyntaxError.error1013

  let expect_right_double_angle parser =
    expect_token parser TokenKind.GreaterThanGreaterThan SyntaxError.error1029

  let expect_left_bracket parser =
    expect_token parser TokenKind.LeftBracket SyntaxError.error1026

  let expect_right_bracket parser =
    expect_token parser TokenKind.RightBracket SyntaxError.error1032

  let expect_equal parser =
    expect_token parser TokenKind.Equal SyntaxError.error1036

  let expect_arrow parser =
    expect_token parser TokenKind.EqualGreaterThan SyntaxError.error1028

  let expect_lambda_arrow parser =
    expect_token parser TokenKind.EqualEqualGreaterThan SyntaxError.error1046

  let expect_as parser =
    expect_token parser TokenKind.As SyntaxError.error1023

  let expect_while parser =
    expect_token parser TokenKind.While SyntaxError.error1018

  let expect_coloncolon parser =
    expect_token parser TokenKind.ColonColon SyntaxError.error1047

  let expect_name_or_variable parser =
    let (parser1, token) = next_token_as_name parser in
    match Token.kind token with
    | TokenKind.Name
    | TokenKind.Variable -> (parser1, Syntax.make_token token)
    | _ ->
      (* ERROR RECOVERY: Create a missing token for the expected token,
         and continue on from the current token. Don't skip it. *)
      (with_error parser SyntaxError.error1050, (Syntax.make_missing()))

  let expect_name_variable_or_class parser =
    let (parser1, token) = next_token parser in
    if Token.kind token = TokenKind.Class then
      (parser1, Syntax.make_token token)
    else
      let (parser1, token) = next_token_as_name parser in
      match Token.kind token with
      | TokenKind.Name
      | TokenKind.Variable -> (parser1, Syntax.make_token token)
      | _ ->
        (* ERROR RECOVERY: Create a missing token for the expected token,
           and continue on from the current token. Don't skip it. *)
        (with_error parser SyntaxError.error1048, (Syntax.make_missing()))

  let optional_token parser kind =
    let (parser1, token) = next_token parser in
    if (Token.kind token) = kind then
      (parser1, Syntax.make_token token)
    else
      (parser, Syntax.make_missing())

  let assert_token parser kind =
    let (parser, token) = next_token parser in
    assert ((Token.kind token) = kind);
    (parser, Syntax.make_token token)

  (* This helper method parses a list of the form

    open_token item separator_token item ... close_token

    * We assume that open_token has already been consumed.
    * We do not consume the close_token.
    * The given error will be produced if an expected item is missing.
    * The caller is responsible for producing an error if the close_token
      is missing.
    * We expect at least one item.
    * If the list of items is empty then a Missing node is returned.
    * If the list of items is a singleton then the item is returned.
    * Otherwise, a list of the form (item, separator) ... item is returned.
*)

  let parse_separated_list parser separator_kind allow_trailing
      close_kind error parse_item =
    let rec aux parser acc =
      (* At this point we are expecting an item followed by a separator,
         a close, or, if trailing separators are allowed, both *)
      let (parser1, token) = next_token parser in
      let kind = Token.kind token in
      if kind = close_kind || kind = TokenKind.EndOfFile then
        (* ERROR RECOVERY: We expected an item but we found a close or
           the end of the file. Make the item "missing" and give an error. *)
        let parser = with_error parser error in
        let item = Syntax.make_missing() in
        (parser, (item :: acc))
      else if kind = separator_kind then

        (* ERROR RECOVERY: We expected an item but we got a separator.
           Assume the item was missing, eat the separator, and move on.
           TODO: This could be poor recovery. For example:

                function bar (Foo< , int blah)

          Plainly the type arg is missing, but the comma is not associated with
          the type argument list, it's associated with the formal
          parameter list.  *)

        let parser = with_error parser1 error in
        let item = Syntax.make_missing() in
        let separator = Syntax.make_token token in
        let list_item = Syntax.make_list_item item separator  in
        aux parser (list_item :: acc)
      else

        (* We got neither a close nor a separator; hopefully we're going
           to parse an item followed by a close or separator. *)
        let (parser, item) = parse_item parser in
        let (parser1, token) = next_token parser in
        let kind = Token.kind token in
        if kind = close_kind then
          (parser, (item :: acc))
        else if kind = separator_kind then
          let separator = Syntax.make_token token in
          let list_item = Syntax.make_list_item item separator in
          let acc = list_item :: acc in
          (* We got an item followed by a separator; what if the thing
             that comes next is a close? *)
          if allow_trailing && (peek_token_kind parser1) = close_kind then
            (parser1, acc)
          else
            aux parser1 acc
        else
          (* ERROR RECOVERY: We were expecting a close or separator, but
             got neither. Bail out. Caller will give an error. *)
          (parser, (item :: acc)) in
    let (parser, items) = aux parser [] in
    (parser, Syntax.make_list (List.rev items))

  let parse_separated_list_opt
      parser separator_kind allow_trailing close_kind error parse_item =
    let token = peek_token parser in
    let kind = Token.kind token in
    if kind = close_kind then
      (parser, Syntax.make_missing())
    else
      parse_separated_list
        parser separator_kind allow_trailing close_kind error parse_item

  let parse_comma_list parser =
    parse_separated_list parser TokenKind.Comma false

  let parse_comma_list_allow_trailing parser =
    parse_separated_list parser TokenKind.Comma true

  let parse_comma_list_opt parser =
    parse_separated_list_opt parser TokenKind.Comma false

  let parse_comma_list_opt_allow_trailing parser =
    parse_separated_list_opt parser TokenKind.Comma true

  let parse_semi_list parser =
    parse_separated_list parser TokenKind.Semicolon false

  let parse_semi_list_opt parser =
    parse_separated_list_opt parser TokenKind.Semicolon false

  let parse_delimited_list
      parser left_kind left_error right_kind right_error parse_items =
    let (parser, left) = expect_token parser left_kind left_error in
    let (parser, items) = parse_items parser in
    let (parser, right) = expect_token parser right_kind right_error in
    (parser, left, items, right)

  let parse_parenthesized_list parser parse_items =
    parse_delimited_list parser TokenKind.LeftParen SyntaxError.error1019
      TokenKind.RightParen SyntaxError.error1011 parse_items

  let parse_parenthesized_comma_list_opt parser parse_item =
    let parse_items parser =
      parse_comma_list_opt
        parser TokenKind.RightParen SyntaxError.error1011 parse_item in
    parse_parenthesized_list parser parse_items

  let parse_parenthesized_comma_list_opt_allow_trailing parser parse_item =
    let parse_items parser =
      parse_comma_list_opt_allow_trailing
        parser TokenKind.RightParen SyntaxError.error1011 parse_item in
    parse_parenthesized_list parser parse_items

end
