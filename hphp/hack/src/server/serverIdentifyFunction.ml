(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Core
open ServerEnv

(* Identifying a symbol can be a first step to another operation. For example,
 * you can identify symbol and then highlight other "equal" symbols.
 * get_occurrence_and_map is useful for such application, because ~f function
 * will execute in the same environment that the symbol was identified -
 * content ASTs and defs will still be available in shared memory for the
 * subsequent operation. *)
let get_occurrence_and_map content line char ~f =
  let result = ref [] in
  IdentifySymbolService.attach_hooks result line char;
  ServerIdeUtils.declare_and_check content ~f:begin fun path file_info ->
    IdentifySymbolService.detach_hooks ();
    f path file_info !result
  end

let get_full_occurrence_pair content =
  let result = ref [] in
  IdentifySymbolService.attach_full_hooks result;
  ServerIdeUtils.declare_and_check content ~f:begin fun path file_info ->
    let ast = Parser_heap.ParserHeap.find_unsafe path in
    IdentifySymbolService.detach_hooks ();
    (path, file_info, ast, !result)
  end

let get_occurrence content line char =
  get_occurrence_and_map content line char ~f:(fun _ _ x -> x)

let go content line char tcopt =
  get_occurrence_and_map content line char ~f:(fun path _ symbols ->
    let ast = Parser_heap.ParserHeap.find_unsafe path in
    List.map symbols ~f:(fun x ->
      let symbol_definition = ServerSymbolDefinition.go tcopt ast x in
      x, symbol_definition
    )
  )

let go_from_file (p, line, column) env =
  let (path, file_info, ast, symbols) = SMap.find_unsafe p env.symbols_cache in
  let symbols = List.filter symbols (fun symbol ->
    IdentifySymbolService.is_target line column symbol.SymbolOccurrence.pos) in
  ServerIdeUtils.oldify_file_info path file_info;
  Parser_heap.ParserHeap.add path ast;
  let res = List.map symbols ~f:(fun x ->
    let symbol_definition = ServerSymbolDefinition.go env.tcopt ast x in
    x, symbol_definition
  ) in
  ServerIdeUtils.revive_file_info path file_info;
  List.map res begin fun (x, y) ->
    SymbolOccurrence.to_absolute x, Option.map y SymbolDefinition.to_absolute
  end

let go_absolute content line char tcopt =
  List.map (go content line char tcopt) begin fun (x, y) ->
    SymbolOccurrence.to_absolute x, Option.map y SymbolDefinition.to_absolute
  end
