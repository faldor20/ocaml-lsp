open Import
open Fiber.O

module Resolve = struct
  type t = CompletionParams.t

  let uri (t : t) = t.textDocument.uri

  let yojson_of_t = CompletionParams.yojson_of_t

  let t_of_yojson = CompletionParams.t_of_yojson

  let of_completion_item (ci : CompletionItem.t) =
    Option.map ci.data ~f:t_of_yojson
end

let completion_kind kind : CompletionItemKind.t option =
  match kind with
  | `Value -> Some Value
  | `Variant -> Some EnumMember
  | `Label -> Some Field
  | `Module -> Some Module
  | `Modtype -> Some Interface
  | `MethodCall -> Some Method
  | `Keyword -> Some Keyword
  | `Constructor -> Some Constructor
  | `Type -> Some TypeParameter

(* I should just rewrite all of this so that it uses a nice for loop. This
   current soluction is a nice try but overall crap we need to be able to look
   ahead and behind

   Split it into name and infix name is obvious infix can be either a dot, a
   label or an I could possibly do a regex based parser.

   Name regex: ((\w)|\w.)*$ *)

let prefix_of_position_old ~short_path source position =
  match Msource.text source with
  | "" -> ""
  | text ->
    let from =
      let (`Offset index) = Msource.get_offset source position in
      min (String.length text - 1) (index - 1)
    in
    let pos =
      let should_terminate = ref false in
      let has_seen_dot = ref false in
      let is_prefix_char c =
        if !should_terminate then false
        else
          match c with
          | 'a' .. 'z'
          | 'A' .. 'Z'
          | '0' .. '9'
          | '\''
          | '_'
          (* Infix function characters *)
          | '$'
          | '&'
          | '*'
          | '+'
          | '-'
          | '/'
          | '='
          | '>'
          | '@'
          | '^'
          | '!'
          | '?'
          | '%'
          | '<'
          | ':'
          | '~'
          | '#' -> true
          | '`' ->
            if !has_seen_dot then false
            else (
              should_terminate := true;
              true)
          | '.' ->
            has_seen_dot := true;
            not short_path
          | _ -> false
      in
      String.rfindi text ~from ~f:(fun c -> not (is_prefix_char c))
    in
    let pos =
      match pos with
      | None -> 0
      | Some pos -> pos + 1
    in
    let len = from - pos + 1 in
    let reconstructed_prefix = String.sub text ~pos ~len in
    (* if we reconstructed [~f:ignore] or [?f:ignore], we should take only
       [ignore], so: *)
    if
      String.is_prefix reconstructed_prefix ~prefix:"~"
      || String.is_prefix reconstructed_prefix ~prefix:"?"
    then
      match String.lsplit2 reconstructed_prefix ~on:':' with
      | Some (_, s) -> s
      | None -> reconstructed_prefix
    else reconstructed_prefix

let prefix_of_position_parser ~short_path source position =
  let open Prefix_parser in
  match Msource.text source with
  | "" -> ""
  | text ->
    let end_of_prefix =
      let (`Offset index) = Msource.get_offset source position in
      min (String.length text - 1) (index - 1)
    in
    (*TODO this is a mess and could be a lot faster*)
    let prefix_text =
      String.sub text ~pos:0 ~len:(end_of_prefix + 1)
      |> String.to_seq |> List.of_seq |> List.rev
    in

    (*Printf.printf "trying to parse text `%s`\n"
      (prefix_text|>String.of_list);*)
    let prefix_length =
      match prefix_text with
      | c :: next_char :: _ when c |> is_name_char ~next_char ->
        (*Printf.printf "trying to parse as name or label";*)
        prefix_text |> try_parse [ name_prefix ]
      | x ->
        (*Printf.printf "trying to parse as infix";*)
        x |> try_parse [ infix_prefix ]
    in

    let len =
      match prefix_length with
      | None -> 0
      | Some len -> len
    in
    let pos = end_of_prefix - len + 1 in
    let reconstructed_prefix = String.sub text ~pos ~len in
    if short_path then
      match String.split_on_char reconstructed_prefix ~sep:'.' |> List.last with
      | Some s -> s
      | None -> reconstructed_prefix
    else reconstructed_prefix

let prefix_of_position ~short_path source position =
  let open Prefix_parser in
  match Msource.text source with
  | "" -> ""
  | text ->
    let end_of_prefix =
      let (`Offset index) = Msource.get_offset source position in
      min (String.length text - 1) (index - 1)
    in
    let prefix_text =
      (*We do prevent completion from working across multiple lines here. But
        this is probably an okay aproximation. We could add the the regex or
        parser the fact that whitespace doesn't really matter in certain cases
        like "List. map"*)
      let pos =
        (* text |> String.rfindi ~from:end_of_prefix ~f:(( = ) '\n') |>
           Option.value ~default:0 *)

        (*clamp the length of a line to process at 500 chars*)
        max 0 (end_of_prefix - 500)
      in
      String.sub text ~pos ~len:(end_of_prefix + 1 - pos)
      |> String.map ~f:(fun x -> if x = '\n'||x='\t' then ' ' else x)
    in

    (*Printf.printf "trying to parse text `%s`\n"
      (prefix_text|>String.of_list);*)
    let reconstructed_prefix =
      try_parse_regex prefix_text |> Option.value ~default:"" |>String.filter_map ~f:(fun x-> if x=' ' then None else Some x )

    in
    if short_path then
      match String.split_on_char reconstructed_prefix ~sep:'.' |> List.last with
      | Some s -> s
      | None -> reconstructed_prefix
    else reconstructed_prefix

(** [suffix_of_position source position] computes the suffix of the identifier
    after [position]. *)
let suffix_of_position source position =
  match Msource.text source with
  | "" -> ""
  | text ->
    let (`Offset index) = Msource.get_offset source position in
    let len = String.length text in
    if index >= len then ""
    else
      let from = index in
      let len =
        let ident_char = function
          | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '\'' | '_' -> true
          | _ -> false
        in
        let until =
          String.findi ~from text ~f:(fun c -> not (ident_char c))
          |> Option.value ~default:len
        in
        until - from
      in
      String.sub text ~pos:from ~len

let reconstruct_ident source position =
  let prefix = prefix_of_position ~short_path:false source position in
  let suffix = suffix_of_position source position in
  let ident = prefix ^ suffix in
  Option.some_if (ident <> "") ident

let range_prefix (lsp_position : Position.t) prefix : Range.t =
  let start =
    let len = String.length prefix in
    let character = lsp_position.character - len in
    { lsp_position with character }
  in
  { Range.start; end_ = lsp_position }

let sortText_of_index idx = Printf.sprintf "%04d" idx

module Complete_by_prefix = struct
  let completionItem_of_completion_entry idx
      (entry : Query_protocol.Compl.entry) ~compl_params ~range ~deprecated =
    let kind = completion_kind entry.kind in
    let textEdit = `TextEdit { TextEdit.range; newText = entry.name } in
    CompletionItem.create
      ~label:entry.name
      ?kind
      ~detail:entry.desc
      ?deprecated:(Option.some_if deprecated entry.deprecated)
        (* Without this field the client is not forced to respect the order
           provided by merlin. *)
      ~sortText:(sortText_of_index idx)
      ?data:compl_params
      ~textEdit
      ()

  let dispatch_cmd ~prefix position pipeline =
    let complete =
      Query_protocol.Complete_prefix (prefix, position, [], false, true)
    in
    Query_commands.dispatch pipeline complete

  let process_dispatch_resp ~deprecated ~resolve doc pos
      (completion : Query_protocol.completions) =
    let range =
      let logical_pos = Position.logical pos in
      range_prefix
        pos
        (prefix_of_position
           ~short_path:true
           (Document.Merlin.source doc)
           logical_pos)
    in
    let completion_entries =
      match completion.context with
      | `Unknown -> completion.entries
      | `Application { Query_protocol.Compl.labels; argument_type = _ } ->
        completion.entries
        @ List.map labels ~f:(fun (name, typ) ->
              { Query_protocol.Compl.name
              ; kind = `Label
              ; desc = typ
              ; info = ""
              ; deprecated = false (* TODO this is wrong *)
              })
    in
    (* we need to json-ify completion params to put them in completion item's
       [data] field to keep it across [textDocument/completion] and the
       following [completionItem/resolve] requests *)
    let compl_params =
      match resolve with
      | false -> None
      | true ->
        Some
          (let textDocument =
             TextDocumentIdentifier.create
               ~uri:(Document.uri (Document.Merlin.to_doc doc))
           in
           CompletionParams.create ~textDocument ~position:pos ()
           |> CompletionParams.yojson_of_t)
    in
    List.mapi
      completion_entries
      ~f:(completionItem_of_completion_entry ~deprecated ~range ~compl_params)

  let complete doc prefix pos ~deprecated ~resolve =
    let+ (completion : Query_protocol.completions) =
      let logical_pos = Position.logical pos in
      Document.Merlin.with_pipeline_exn
        ~name:"completion-prefix"
        doc
        (dispatch_cmd ~prefix logical_pos)
    in
    process_dispatch_resp ~deprecated ~resolve doc pos completion
end

module Complete_with_construct = struct
  let dispatch_cmd position pipeline =
    match
      Exn_with_backtrace.try_with (fun () ->
          let command = Query_protocol.Construct (position, None, None) in
          Query_commands.dispatch pipeline command)
    with
    | Ok (loc, exprs) -> Some (loc, exprs)
    | Error { Exn_with_backtrace.exn = Merlin_analysis.Construct.Not_a_hole; _ }
      -> None
    | Error exn -> Exn_with_backtrace.reraise exn

  let process_dispatch_resp ~supportsJumpToNextHole = function
    | None -> []
    | Some (loc, constructed_exprs) ->
      let range = Range.of_loc loc in
      let deparen_constr_expr expr =
        if
          (not (String.equal expr "()"))
          && String.is_prefix expr ~prefix:"("
          && String.is_suffix expr ~suffix:")"
        then String.sub expr ~pos:1 ~len:(String.length expr - 2)
        else expr
      in
      let completionItem_of_constructed_expr idx expr =
        let expr_wo_parens = deparen_constr_expr expr in
        let edit = { TextEdit.range; newText = expr } in
        let command =
          if supportsJumpToNextHole then
            Some
              (Client.Custom_commands.next_hole
                 ~in_range:(Range.resize_for_edit edit)
                 ~notify_if_no_hole:false
                 ())
          else None
        in
        CompletionItem.create
          ~label:expr_wo_parens
          ~textEdit:(`TextEdit edit)
          ~filterText:("_" ^ expr)
          ~kind:CompletionItemKind.Text
          ~sortText:(sortText_of_index idx)
          ?command
          ()
      in
      List.mapi constructed_exprs ~f:completionItem_of_constructed_expr
end

let logCompletion log =
  Log.log ~section:"resolveCompletion" (fun () -> Log.msg log [])

let complete (state : State.t)
    ({ textDocument = { uri }; position = pos; _ } : CompletionParams.t) =
  logCompletion "ho1";
  Fiber.of_thunk (fun () ->
      let doc = Document_store.get state.store uri in
      match Document.kind doc with
      | `Other -> Fiber.return None
      | `Merlin merlin ->
        let completion_item_capability =
          let open Option.O in
          let capabilities = State.client_capabilities state in
          let* td = capabilities.textDocument in
          let* compl = td.completion in
          compl.completionItem
        in
        let resolve =
          match
            let open Option.O in
            let* item = completion_item_capability in
            item.resolveSupport
          with
          | None -> false
          | Some { properties } ->
            List.mem properties ~equal:String.equal "documentation"
        in
        let+ items =
          let position = Position.logical pos in
          let prefix =
            prefix_of_position ~short_path:false (Document.source doc) position
          in
          let deprecated =
            Option.value
              ~default:false
              (let open Option.O in
              let* item = completion_item_capability in
              item.deprecatedSupport)
          in
          logCompletion
            (Printf.sprintf
               "prefix: %s; position %i:%i"
               prefix
               pos.line
               pos.character);
          if not (Typed_hole.can_be_hole prefix) then
            Complete_by_prefix.complete merlin prefix pos ~resolve ~deprecated
          else
            let reindex_sortText completion_items =
              List.mapi completion_items ~f:(fun idx (ci : CompletionItem.t) ->
                  let sortText = Some (sortText_of_index idx) in
                  { ci with sortText })
            in
            let preselect_first =
              match
                let open Option.O in
                let* item = completion_item_capability in
                item.preselectSupport
              with
              | None | Some false -> fun x -> x
              | Some true -> (
                function
                | [] -> []
                | ci :: rest ->
                  { ci with CompletionItem.preselect = Some true } :: rest)
            in
            let+ construct_cmd_resp, compl_by_prefix_resp =
              Document.Merlin.with_pipeline_exn
                ~name:"completion"
                merlin
                (fun pipeline ->
                  let construct_cmd_resp =
                    Complete_with_construct.dispatch_cmd position pipeline
                  in
                  let compl_by_prefix_resp =
                    Complete_by_prefix.dispatch_cmd ~prefix position pipeline
                  in
                  (construct_cmd_resp, compl_by_prefix_resp))
            in
            let construct_completionItems =
              let supportsJumpToNextHole =
                State.experimental_client_capabilities state
                |> Client.Experimental_capabilities.supportsJumpToNextHole
              in
              Complete_with_construct.process_dispatch_resp
                ~supportsJumpToNextHole
                construct_cmd_resp
            in
            let compl_by_prefix_completionItems =
              Complete_by_prefix.process_dispatch_resp
                ~resolve
                ~deprecated
                merlin
                pos
                compl_by_prefix_resp
            in
            construct_completionItems @ compl_by_prefix_completionItems
            |> reindex_sortText |> preselect_first
        in
        Some
          (`CompletionList
            (CompletionList.create ~isIncomplete:false ~items ())))

let format_doc ~markdown doc =
  match markdown with
  | false -> `String doc
  | true ->
    `MarkupContent
      (match Doc_to_md.translate doc with
      | Markdown value -> { kind = MarkupKind.Markdown; MarkupContent.value }
      | Raw value -> { kind = MarkupKind.PlainText; MarkupContent.value })

let resolve doc (compl : CompletionItem.t) (resolve : Resolve.t) query_doc
    ~markdown =
  logCompletion "Starting  completion";
  Fiber.of_thunk (fun () ->
      (* Due to merlin's API, we create a version of the given document with the
         applied completion item and pass it to merlin to get the docs for the
         [compl.label] *)
      logCompletion "Starting  completion";
      let position : Position.t = resolve.position in
      let logical_position = Position.logical position in
      let doc =
        let complete =
          let start =
            let prefix =
              prefix_of_position
                ~short_path:true
                (Document.Merlin.source doc)
                logical_position
            in
            logCompletion @@ "completion prefix is:" ^ prefix;
            { position with
              character = position.character - String.length prefix
            }
          in
          let end_ =
            let suffix =
              suffix_of_position (Document.Merlin.source doc) logical_position
            in
            { position with
              character = position.character + String.length suffix
            }
          in

          let range = Range.create ~start ~end_ in

          TextDocumentContentChangeEvent.create ~range ~text:compl.label ()
        in
        Document.update_text (Document.Merlin.to_doc doc) [ complete ]
      in
      let+ documentation =
        let+ documentation =
          query_doc (Document.merlin_exn doc) logical_position
        in
        Option.map ~f:(format_doc ~markdown) documentation
      in
      { compl with documentation; data = None })
