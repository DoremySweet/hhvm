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
open Reordered_argument_collections
open String_utils

type recheck_loop_stats = {
  rechecked_batches : int;
  rechecked_count : int;
  (* includes dependencies *)
  total_rechecked_count : int;
}

type main_loop_stats = recheck_loop_stats ref * string ref

let empty_recheck_loop_stats = {
  rechecked_batches = 0;
  rechecked_count = 0;
  total_rechecked_count = 0;
}

let get_rechecked_count (stats_ref, _) = !stats_ref.rechecked_count

(*****************************************************************************)
(* Main initialization *)
(*****************************************************************************)

module MainInit : sig
  val go:
    ServerArgs.options ->
    (unit -> env) ->    (* init function to run while we have init lock *)
    env
end = struct
  (* This code is only executed when the options --check is NOT present *)
  let go options init_fun =
    let root = ServerArgs.root options in
    let t = Unix.gettimeofday () in
    Hh_logger.log "Initializing Server (This might take some time)";
    (* note: we only run periodical tasks on the root, not extras *)
    ServerIdle.init root;
    let init_id = Random_id.short_string () in
    Hh_logger.log "Init id: %s" init_id;
    let env = HackEventLogger.with_id ~stage:`Init init_id init_fun in
    Hh_logger.log "Server is READY";
    let t' = Unix.gettimeofday () in
    Hh_logger.log "Took %f seconds to initialize." (t' -. t);
    env
end

module Program =
  struct
    let preinit () =
      (* Warning: Global references inited in this function, should
         be 'restored' in the workers, because they are not 'forked'
         anymore. See `ServerWorker.{save/restore}_state`. *)
      HackSearchService.attach_hooks ();
      Sys_utils.set_signal Sys.sigusr1
        (Sys.Signal_handle Typing.debug_print_last_pos);
      Sys_utils.set_signal Sys.sigusr2
        (Sys.Signal_handle (fun _ -> (
             Hh_logger.log "Got sigusr2 signal. Going to shut down.";
             Exit_status.exit Exit_status.Server_shutting_down
           )))

    let run_once_and_exit genv env =
      ServerError.print_errorl
        (ServerArgs.json_mode genv.options)
        (List.map (Errors.get_error_list env.errorl) Errors.to_absolute) stdout;
      match ServerArgs.convert genv.options with
      | None ->
         Worker.killall ();
         exit (if Errors.is_empty env.errorl then 0 else 1)
      | Some dirname ->
         ServerConvert.go genv env dirname;
         Worker.killall ();
         exit 0

    (* filter and relativize updated file paths *)
    let process_updates genv _env updates =
      let root = Path.to_string @@ ServerArgs.root genv.options in
      (* Because of symlinks, we can have updates from files that aren't in
       * the .hhconfig directory *)
      let updates = SSet.filter updates (fun p -> string_starts_with p root) in
      Relative_path.(relativize_set Root updates)

    let recheck genv old_env typecheck_updates =
      if Relative_path.Set.is_empty typecheck_updates then
        old_env, 0
      else begin
        let failed_parsing =
          Relative_path.Set.union typecheck_updates old_env.failed_parsing in
        let check_env = { old_env with failed_parsing = failed_parsing } in
        let new_env, total_rechecked = ServerTypeCheck.check genv check_env in
        ServerStamp.touch_stamp_errors (Errors.get_error_list old_env.errorl)
                                       (Errors.get_error_list new_env.errorl);
        Option.iter new_env.diag_subscribe ~f:begin fun sub ->
          let id = Diagnostic_subscription.get_id sub in
          let errors = Errors.get_error_list new_env.errorl in
          let errors = List.map ~f:Errors.to_absolute errors in
          let res = ServerCommandTypes.DIAGNOSTIC (id, errors) in
          let client = Utils.unsafe_opt new_env.persistent_client in
          ClientProvider.send_push_message_to_client client res;
        end;
        new_env, total_rechecked
      end

  end

(*****************************************************************************)
(* The main loop *)
(*****************************************************************************)

let handle_connection_ genv env client =
  let open ServerCommandTypes in
  try
    match ClientProvider.read_connection_type client with
    | Persistent ->
      (match env.persistent_client with
      | Some _ ->
        ClientProvider.send_response_to_client client
          Persistent_client_alredy_exists;
        env
      | None ->
        ClientProvider.send_response_to_client client
          Persistent_client_connected;
        { env with persistent_client =
            Some (ClientProvider.make_persistent client)})
    | Non_persistent ->
      ServerCommand.handle genv env client
  with
  | Sys_error("Broken pipe") | Read_command_timeout ->
    ClientProvider.shutdown_client client;
    env
  | e ->
    let msg = Printexc.to_string e in
    EventLogger.master_exception msg;
    Printf.fprintf stderr "Error: %s\n%!" msg;
    Printexc.print_backtrace stderr;
    ClientProvider.shutdown_client client;
    env

let handle_persistent_connection_ genv env client =
   try
     ServerCommand.handle genv env client
   with
   | Sys_error("Broken pipe") | ServerCommandTypes.Read_command_timeout ->
     ClientProvider.shutdown_client client;
     {env with
     persistent_client = None;
     edited_files = Relative_path.Map.empty;
     diag_subscribe = None;
     symbols_cache = SMap.empty}
   | e ->
     let msg = Printexc.to_string e in
     EventLogger.master_exception msg;
     Printf.fprintf stderr "Error: %s\n%!" msg;
     Printexc.print_backtrace stderr;
     ClientProvider.shutdown_client client;
     {env with
     persistent_client = None;
     edited_files = Relative_path.Map.empty;
     diag_subscribe = None;
     symbols_cache = SMap.empty}

let handle_connection genv env client is_persistent =
  ServerIdle.stamp_connection ();
  try match is_persistent with
    | true -> handle_persistent_connection_ genv env client
    | false -> handle_connection_ genv env client
  with
  | Unix.Unix_error (e, _, _) ->
     Printf.fprintf stderr "Unix error: %s\n" (Unix.error_message e);
     Printexc.print_backtrace stderr;
     flush stderr;
     env
  | e ->
     Printf.fprintf stderr "Error: %s\n" (Printexc.to_string e);
     Printexc.print_backtrace stderr;
     flush stderr;
     env

let recheck genv old_env updates =
  let to_recheck =
    Relative_path.Set.filter updates begin fun update ->
      ServerEnv.file_filter (Relative_path.suffix update)
    end in
  let config_in_updates =
    Relative_path.Set.mem updates ServerConfig.filename in
  if config_in_updates then begin
    let new_config, _ = ServerConfig.(load filename genv.options) in
    if not (ServerConfig.is_compatible genv.config new_config) then begin
      Hh_logger.log
        "%s changed in an incompatible way; please restart %s.\n"
        (Relative_path.suffix ServerConfig.filename)
        GlobalConfig.program_name;
       (** TODO: Notify the server monitor directly about this. *)
       Exit_status.(exit Hhconfig_changed)
    end;
  end;
  let env, total_rechecked = Program.recheck genv old_env to_recheck in
  BuildMain.incremental_update genv old_env env updates;
  env, to_recheck, total_rechecked

(* When a rebase occurs, dfind takes a while to give us the full list of
 * updates, and it often comes in batches. To get an accurate measurement
 * of rebase time, we use the heuristic that any changes that come in
 * right after one rechecking round finishes to be part of the same
 * rebase, and we don't log the recheck_end event until the update list
 * is no longer getting populated. *)
let rec recheck_loop acc genv env =
  let t = Unix.gettimeofday () in
  let raw_updates = genv.notifier () in

  let is_idle = t -. env.last_command_time > 0.5 in

  let disk_recheck = not (SSet.is_empty raw_updates) in
  let ide_recheck =
    (not @@ Relative_path.Set.is_empty env.files_to_check) && is_idle in
  if (not disk_recheck) && (not ide_recheck) then
    acc, env
  else begin
    HackEventLogger.notifier_returned t (SSet.cardinal raw_updates);
    let updates = Program.process_updates genv env raw_updates in
    let updates = Relative_path.Set.union updates env.files_to_check in
    let env, rechecked, total_rechecked = recheck genv env updates in
    let acc = {
      rechecked_batches = acc.rechecked_batches + 1;
      rechecked_count =
        acc.rechecked_count + Relative_path.Set.cardinal rechecked;
      total_rechecked_count = acc.total_rechecked_count + total_rechecked;
    } in
    recheck_loop acc genv env
  end

let recheck_loop = recheck_loop empty_recheck_loop_stats

let serve_one_iteration genv env client_provider stats_refs =
  let last_stats, recheck_id = stats_refs in
  ServerMonitorUtils.exit_if_parent_dead ();
  let has_client, has_persistent =
    ClientProvider.sleep_and_check client_provider env.persistent_client in
  let has_parsing_hook = !ServerTypeCheck.hook_after_parsing <> None in
  if not has_persistent && not has_client && not has_parsing_hook
  then begin
    (* Ugly hack: We want GC_SHAREDMEM_RAN to record the last rechecked
     * count so that we can figure out if the largest reclamations
     * correspond to massive rebases. However, the logging call is done in
     * the SharedMem module, which doesn't know anything about Server stuff.
     * So we wrap the call here. *)
    HackEventLogger.with_rechecked_stats
      !last_stats.rechecked_batches
      !last_stats.rechecked_count
      !last_stats.total_rechecked_count
      ServerIdle.go;
    recheck_id := Random_id.short_string ();
  end;
  let start_t = Unix.gettimeofday () in
  HackEventLogger.with_id ~stage:`Recheck !recheck_id @@ fun () ->
  let stats, env = recheck_loop genv env in
  if stats.rechecked_count > 0 then begin
    HackEventLogger.recheck_end start_t has_parsing_hook
      stats.rechecked_batches
      stats.rechecked_count
      stats.total_rechecked_count;
    Hh_logger.log "Recheck id: %s" !recheck_id;
  end;
  last_stats := stats;
  let env = if has_client then
    (try
      let client = ClientProvider.accept_client client_provider in
      HackEventLogger.got_client_channels start_t;
      (try
        let env = handle_connection genv env client false in
        HackEventLogger.handled_connection start_t;
        env
      with
      | e ->
        HackEventLogger.handle_connection_exception e;
        Hh_logger.log "Handling client failed. Ignoring.";
        env)
    with
    | e ->
      HackEventLogger.get_client_channels_exception e;
      Hh_logger.log
        "Getting Client FDs failed. Ignoring.";
      env)
  else env in
  if has_persistent then
    let client = Utils.unsafe_opt env.persistent_client in
    HackEventLogger.got_persistent_client_channels start_t;
    (try
      let env = handle_connection genv env client true in
      HackEventLogger.handled_persistent_connection start_t;
      env
    with
    | e ->
      HackEventLogger.handle_persistent_connection_exception e;
      Hh_logger.log "Handling persistent client failed. Ignoring.";
      env)
  else env

let empty_stats () =
  (ref empty_recheck_loop_stats,
  ref (Random_id.short_string ()))

let serve genv env in_fd _ =
  let client_provider = ClientProvider.provider_from_file_descriptor in_fd in
  let env = ref env in
  let stats = empty_stats () in
  while true do
    env := serve_one_iteration genv !env client_provider stats;
  done

let program_init genv =
  let env, init_type =
    (* If we are saving, always start from a fresh state -- just in case
     * incremental mode introduces any errors. *)
    if genv.local_config.ServerLocalConfig.use_mini_state &&
      not (ServerArgs.no_load genv.options) &&
      ServerArgs.save_filename genv.options = None then
      match ServerConfig.load_mini_script genv.config with
      | None ->
        let env, _ = ServerInit.init genv in
        env, "fresh"
      | Some load_mini_script ->
        let env, did_load = ServerInit.init ~load_mini_script genv in
        env, if did_load then "mini_load" else "mini_load_fail"
    else
      let env, _ = ServerInit.init genv in
      env, "fresh"
  in
  HackEventLogger.init_end init_type;
  Hh_logger.log "Waiting for daemon(s) to be ready...";
  genv.wait_until_ready ();
  ServerStamp.touch_stamp ();
  HackEventLogger.init_really_end init_type;
  env

let setup_server options handle =
  Hh_logger.log "Version: %s" Build_id.build_id_ohai;
  let root = ServerArgs.root options in
  (* The OCaml default is 500, but we care about minimizing the memory
   * overhead *)
  let gc_control = Gc.get () in
  Gc.set {gc_control with Gc.max_overhead = 200};
  let config, local_config = ServerConfig.(load filename options) in
  let {ServerLocalConfig.
    cpu_priority;
    io_priority;
    enable_on_nfs;
    lazy_decl;
    _
  } as local_config = local_config in
  if Sys_utils.is_test_mode ()
  then EventLogger.init (Daemon.devnull ()) 0.0
  else HackEventLogger.init root (Unix.gettimeofday ()) lazy_decl;
  let root_s = Path.to_string root in
  if Sys_utils.is_nfs root_s && not enable_on_nfs then begin
    Hh_logger.log "Refusing to run on %s: root is on NFS!" root_s;
    HackEventLogger.nfs_root ();
    Exit_status.(exit Nfs_root);
  end;

  Program.preinit ();
  Sys_utils.set_priorities ~cpu_priority ~io_priority;
  (* this is to transform SIGPIPE in an exception. A SIGPIPE can happen when
   * someone C-c the client.
   *)
  Sys_utils.set_signal Sys.sigpipe Sys.Signal_ignore;
  PidLog.init (ServerFiles.pids_file root);
  PidLog.log ~reason:"main" (Unix.getpid());
  ServerEnvBuild.make_genv options config local_config handle

let run_once options handle =
  let genv = setup_server options handle in
  if not (ServerArgs.check_mode genv.options) then
    (Hh_logger.log "ServerMain run_once only supported in check mode.";
    Exit_status.(exit Input_error));
  let env = program_init genv in
  Option.iter (ServerArgs.save_filename genv.options)
    (ServerInit.save_state env);
  Hh_logger.log "Running in check mode";
  Program.run_once_and_exit genv env

(*
 * The server monitor will pass client connections to this process
 * via ic.
 *)
let daemon_main_exn (handle, options) (ic, oc) =
  let in_fd = Daemon.descr_of_in_channel ic in
  let out_fd = Daemon.descr_of_out_channel oc in

  let genv = setup_server options handle in
  if ServerArgs.check_mode genv.options then
    (Hh_logger.log "Invalid program args - can't run daemon in check mode.";
    Exit_status.(exit Input_error));
  let env = MainInit.go options (fun () -> program_init genv) in
  serve genv env in_fd out_fd

let daemon_main (state, handle, options) (ic, oc) =
  (* Even though the server monitor set up the shared memory, the server daemon
   * is master here *)
  SharedMem.connect handle ~is_master:true;
  ServerGlobalState.restore state;
  try daemon_main_exn (handle, options) (ic, oc)
  with
  | SharedMem.Out_of_shared_memory ->
    ServerInit.print_hash_stats ();
    Printf.eprintf "Error: failed to allocate in the shared heap.\n%!";
    Exit_status.(exit Out_of_shared_memory)
  | SharedMem.Hash_table_full ->
    ServerInit.print_hash_stats ();
    Printf.eprintf "Error: failed to allocate in the shared hashtable.\n%!";
    Exit_status.(exit Hash_table_full)

let entry =
  Daemon.register_entry_point "ServerMain.daemon_main" daemon_main
