(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2020 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

open OpamTypes
open OpamTypesBase

let log ?level fmt = OpamConsole.log ?level "CUDF" fmt
let slog = OpamConsole.slog

(* custom cudf field labels *)
let s_source = "opam-name"
let s_source_number = "opam-version"
let s_reinstall = "reinstall"
let s_installed_root = "installed-root"
let s_pinned = "pinned"
let s_version_lag = "version-lag"

let opam_invariant_package_name =
  Common.CudfAdd.encode "=opam-invariant"

let opam_invariant_package_version = 1

let opam_invariant_package =
  opam_invariant_package_name, opam_invariant_package_version

let is_opam_invariant p =
  p.Cudf.package = opam_invariant_package_name

let cudf2opam cpkg =
  if is_opam_invariant cpkg then
    OpamConsole.error_and_exit `Internal_error
      "Internal error: tried to access the CUDF opam invariant as an opam \
       package";
  let sname = Cudf.lookup_package_property cpkg s_source in
  let name = OpamPackage.Name.of_string sname in
  let sver = Cudf.lookup_package_property cpkg s_source_number in
  let version = OpamPackage.Version.of_string sver in
  OpamPackage.create name version

let cudfnv2opam ?version_map ?cudf_universe (name,v) =
  let nv = match cudf_universe with
    | None -> None
    | Some u ->
      try Some (cudf2opam (Cudf.lookup_package u (name,v)))
      with Not_found -> None
  in
  match nv with
  | Some nv -> nv
  | None ->
    let name = OpamPackage.Name.of_string (Common.CudfAdd.decode name) in
    match version_map with
    | Some vmap ->
      let nvset =
        OpamPackage.Map.filter
          (fun nv cv -> nv.name = name && cv = v)
          vmap
      in
      fst (OpamPackage.Map.choose nvset)
    | None -> raise Not_found

let string_of_package p =
  let installed = if p.Cudf.installed then "installed" else "not-installed" in
  Printf.sprintf "%s.%d(%s)"
    p.Cudf.package
    p.Cudf.version installed

let string_of_packages l =
  OpamStd.List.to_string string_of_package l

module Json = struct

  let (>>=) = OpamStd.Option.Op.(>>=)

  let int_to_json n : OpamJson.t = `Float (float_of_int n)
  let int_of_json = function
    | `Float x -> Some (int_of_float x)
    | _ -> None

  let string_to_json s : OpamJson.t = `String s
  let string_of_json = function
    | `String s -> Some s
    | _ -> None

  let pkgname_to_json name : OpamJson.t = string_to_json name
  let pkgname_of_json json = string_of_json json

  let bool_to_json bool : OpamJson.t = `Bool bool
  let bool_of_json = function
    | `Bool b -> Some b
    | _ -> None

  let list_to_json elem_to_json li : OpamJson.t =
    `A (List.map elem_to_json li)
  let list_of_json elem_of_json = function
    | `A jsons ->
      begin try
          let get = function
            | None -> raise Not_found
            | Some v -> v
          in
          Some (List.map (fun json -> get (elem_of_json json)) jsons)
        with Not_found -> None
      end
    | _ -> None

  let option_to_json elem_to_json = function
    | None -> `Null
    | Some elem ->
      let json = elem_to_json elem in
      assert (json <> `Null);
      json
  let option_of_json elem_of_json = function
    | `Null -> Some None
    | other ->
      elem_of_json other >>= fun elem -> Some (Some elem)

  let pair_to_json
      fst_field fst_to_json
      snd_field snd_to_json (fst, snd) =
    `O [(fst_field, fst_to_json fst);
        (snd_field, snd_to_json snd)]

  let pair_of_json
      fst_field fst_of_json
      snd_field snd_of_json : OpamJson.t -> _ = function
    | `O dict ->
      begin try
          fst_of_json (List.assoc fst_field dict) >>= fun fst ->
          snd_of_json (List.assoc snd_field dict) >>= fun snd ->
          Some (fst, snd)
        with Not_found -> None
      end
    | _ -> None

  let version_to_json n = int_to_json n
  let version_of_json json = int_of_json json

  let relop_to_json : Cudf_types.relop -> _ = function
    | `Eq -> `String "eq"
    | `Neq -> `String "neq"
    | `Geq -> `String "geq"
    | `Gt -> `String "gt"
    | `Leq -> `String "leq"
    | `Lt -> `String "lt"

  let relop_of_json : _ -> Cudf_types.relop option = function
    | `String "eq" -> Some `Eq
    | `String "neq" -> Some `Neq
    | `String "geq" -> Some `Geq
    | `String "gt" -> Some `Gt
    | `String "leq" -> Some `Leq
    | `String "lt" -> Some `Lt
    | _ -> None

  let enum_keep_to_json = function
    | `Keep_version -> `String "keep_version"
    | `Keep_package -> `String "keep_package"
    | `Keep_feature -> `String "keep_feature"
    | `Keep_none -> `String "keep_none"
  let enum_keep_of_json = function
    | `String "keep_version" -> Some (`Keep_version)
    | `String "keep_package" -> Some (`Keep_package)
    | `String "keep_feature" -> Some (`Keep_feature)
    | `String "keep_none" -> Some (`Keep_none)
    | _ -> None

  let constr_to_json constr =
    option_to_json
      (pair_to_json "relop" relop_to_json "version" version_to_json)
      constr
  let constr_of_json json =
    option_of_json
      (pair_of_json "relop" relop_of_json "version" version_of_json)
      json

  let vpkg_to_json v =
    pair_to_json "pkgname" pkgname_to_json "constr" constr_to_json v
  let vpkg_of_json json =
    pair_of_json "pkgname" pkgname_of_json "constr" constr_of_json json

  let vpkglist_to_json (vpkglist : Cudf_types.vpkglist) =
    list_to_json vpkg_to_json vpkglist
  let vpkglist_of_json jsons : Cudf_types.vpkglist option =
    list_of_json vpkg_of_json jsons

  let veqpkg_to_json veqpkg = vpkg_to_json (veqpkg :> Cudf_types.vpkg)
  let veqpkg_of_json json =
    vpkg_of_json json >>= function
    | (pkgname, None) -> Some (pkgname, None)
    | (pkgname, Some (`Eq, version)) -> Some (pkgname, Some (`Eq, version))
    | (_pkgname, Some (_, _version)) -> None

  let veqpkglist_to_json veqpkglist = list_to_json veqpkg_to_json veqpkglist
  let veqpkglist_of_json jsons = list_of_json veqpkg_of_json jsons

  let vpkgformula_to_json formula =
    list_to_json (list_to_json vpkg_to_json) formula
  let vpkgformula_of_json json =
    list_of_json (list_of_json vpkg_of_json) json

  let binding_to_json value_to_json v =
    pair_to_json "key" string_to_json "value" value_to_json v
  let binding_of_json value_of_json v =
    pair_of_json "key" string_of_json "value" value_of_json v

  let stanza_to_json value_to_json stanza =
    list_to_json (binding_to_json value_to_json) stanza
  let stanza_of_json value_of_json json =
    list_of_json (binding_of_json value_of_json) json

  let type_schema_to_json tag value_to_json value =
    pair_to_json
      "type" string_to_json
      "default" (option_to_json value_to_json)
      (tag, value)
  let rec typedecl1_to_json = function
    | `Int n ->
      type_schema_to_json "int" int_to_json n
    | `Posint n ->
      type_schema_to_json "posint" int_to_json n
    | `Nat n ->
      type_schema_to_json "nat" int_to_json n
    | `Bool b ->
      type_schema_to_json "bool" bool_to_json b
    | `String s ->
      type_schema_to_json "string" string_to_json s
    | `Pkgname s ->
      type_schema_to_json "pkgname" pkgname_to_json s
    | `Ident s ->
      type_schema_to_json "ident" string_to_json s
    | `Enum (enums, v) ->
      pair_to_json
        "type" string_to_json
        "default" (pair_to_json
                     "set" (list_to_json string_to_json)
                     "default" (option_to_json string_to_json))
        ("enum", (enums, v))
    | `Vpkg v ->
      type_schema_to_json "vpkg" vpkg_to_json v
    | `Vpkgformula v ->
      type_schema_to_json "vpkgformula" vpkgformula_to_json v
    | `Vpkglist v ->
      type_schema_to_json "vpkglist" vpkglist_to_json v
    | `Veqpkg v ->
      type_schema_to_json "veqpkg" veqpkg_to_json v
    | `Veqpkglist v ->
      type_schema_to_json "veqpkglist" veqpkglist_to_json v
    | `Typedecl td ->
      type_schema_to_json "typedecl" typedecl_to_json td
  and typedecl_to_json td =
    stanza_to_json typedecl1_to_json td

  let rec typedecl1_of_json json =
    pair_of_json "type" string_of_json "default" (fun x -> Some x) json >>=
    fun (tag, json) ->
    match tag with
    | "int" -> option_of_json int_of_json json >>= fun x -> Some (`Int x)
    | "posint" -> option_of_json int_of_json json >>= fun x -> Some (`Posint x)
    | "nat" -> option_of_json int_of_json json >>= fun x -> Some (`Nat x)
    | "bool" -> option_of_json bool_of_json json >>= fun x -> Some (`Bool x)
    | "string" -> option_of_json string_of_json json >>= fun x -> Some (`String x)
    | "pkgname" -> option_of_json string_of_json json >>= fun x -> Some (`Pkgname x)
    | "ident" -> option_of_json string_of_json json >>= fun x -> Some (`Ident x)
    | "enum" ->
      pair_of_json
        "set" (list_of_json string_of_json)
        "default" (option_of_json string_of_json)
        json >>= fun x -> Some (`Enum x)
    | "vpkg" ->
      option_of_json vpkg_of_json json >>= fun x -> Some (`Vpkg x)
    | "vpkgformula" ->
      option_of_json vpkgformula_of_json json >>= fun x -> Some (`Vpkgformula x)
    | "vpkglist" ->
      option_of_json vpkglist_of_json json >>= fun x -> Some (`Vpkglist x)
    | "veqpkg" ->
      option_of_json veqpkg_of_json json >>= fun x -> Some (`Veqpkg x)
    | "veqpkglist" ->
      option_of_json veqpkglist_of_json json >>= fun x -> Some (`Veqpkglist x)
    | "typedecl" ->
      option_of_json typedecl_of_json json >>= fun x -> Some (`Typedecl x)
    | _ -> None
  and typedecl_of_json json =
    stanza_of_json typedecl1_of_json json

  let type_tagged_to_json tag value_to_json value =
    pair_to_json "type" string_to_json "value" value_to_json (tag, value)

  let typed_value_to_json : Cudf_types.typed_value -> _ = function
    | `Int n ->
      type_tagged_to_json "int" int_to_json n
    | `Posint n ->
      type_tagged_to_json "posint" int_to_json n
    | `Nat n ->
      type_tagged_to_json "nat" int_to_json n
    | `Bool b ->
      type_tagged_to_json "bool" bool_to_json b
    | `String s ->
      type_tagged_to_json "string" string_to_json s
    | `Pkgname name ->
      type_tagged_to_json "pkgname" pkgname_to_json name
    | `Ident id ->
      type_tagged_to_json "ident" string_to_json id
    | `Enum (enums, value) ->
      type_tagged_to_json "enum"
        (pair_to_json
           "set" (list_to_json string_to_json)
           "choice" string_to_json) (enums, value)
    | `Vpkg vpkg ->
      type_tagged_to_json "vpkg" vpkg_to_json vpkg
    | `Vpkgformula vpkgformula ->
      type_tagged_to_json "vpkgformula" vpkgformula_to_json vpkgformula
    | `Vpkglist vpkglist ->
      type_tagged_to_json "vpkglist" vpkglist_to_json vpkglist
    | `Veqpkg veqpkg ->
      type_tagged_to_json "veqpkg" veqpkg_to_json veqpkg
    | `Veqpkglist veqpkglist ->
      type_tagged_to_json "veqpkglist" veqpkglist_to_json veqpkglist
    | `Typedecl typedecl ->
      type_tagged_to_json "typedecl" typedecl_to_json typedecl

  let typed_value_of_json json : Cudf_types.typed_value option =
    pair_of_json "type" string_of_json "value" (fun x -> Some x) json >>=
    fun (tag, json) ->
    match tag with
    | "int" -> int_of_json json >>= fun x -> Some (`Int x)
    | "posint" -> int_of_json json >>= fun x -> Some (`Posint x)
    | "nat" -> int_of_json json >>= fun x -> Some (`Nat x)
    | "bool" -> bool_of_json json >>= fun x -> Some (`Bool x)
    | "string" -> string_of_json json >>= fun x -> Some (`String x)
    | "pkgname" -> string_of_json json >>= fun x -> Some (`Pkgname x)
    | "ident" -> string_of_json json >>= fun x -> Some (`Ident x)
    | "enum" -> pair_of_json
                     "set" (list_of_json string_of_json)
                     "choice" string_of_json
                     json >>= fun p -> Some (`Enum p)
    | "vpkg" -> vpkg_of_json json >>= fun x -> Some (`Vpkg x)
    | "vpkgformula" -> vpkgformula_of_json json >>= fun x -> Some (`Vpkgformula x)
    | "vpkglist" -> vpkglist_of_json json >>= fun x -> Some (`Vpkglist x)
    | "veqpkg" -> veqpkg_of_json json >>= fun x -> Some (`Veqpkg x)
    | "veqpkglist" -> veqpkglist_of_json json >>= fun x -> Some (`Veqpkglist x)
    | "typedecl" -> typedecl_of_json json >>= fun x -> Some (`Typedecl x)
    | _ -> None

  let package_to_json p =
    `O [ ("name", pkgname_to_json p.Cudf.package);
         ("version", version_to_json p.Cudf.version);
         ("depends", vpkgformula_to_json p.Cudf.depends);
         ("conflicts", vpkglist_to_json p.Cudf.conflicts);
         ("provides", veqpkglist_to_json p.Cudf.provides);
         ("installed", bool_to_json p.Cudf.installed);
         ("was_installed", bool_to_json p.Cudf.was_installed);
         ("keep", enum_keep_to_json p.Cudf.keep);
         ("pkg_extra", stanza_to_json typed_value_to_json p.Cudf.pkg_extra);
       ]

  let package_of_json = function
    | `O dict ->
      begin try
          pkgname_of_json (List.assoc "name" dict) >>= fun package ->
          version_of_json (List.assoc "version" dict) >>= fun version ->
          vpkgformula_of_json (List.assoc "depends" dict) >>= fun depends ->
          vpkglist_of_json (List.assoc "conflicts" dict) >>= fun conflicts ->
          veqpkglist_of_json (List.assoc "provides" dict) >>= fun provides ->
          bool_of_json (List.assoc "installed" dict) >>= fun installed ->
          bool_of_json (List.assoc "was_installed" dict) >>= fun was_installed ->
          enum_keep_of_json (List.assoc "keep" dict) >>= fun keep ->
          stanza_of_json typed_value_of_json (List.assoc "pkg_extra" dict) >>= fun pkg_extra ->
          Some { Cudf.package = package;
            version;
            depends;
            conflicts;
            provides;
            installed;
            was_installed;
            keep;
            pkg_extra;
          }
        with Not_found -> None
      end
    | _ -> None
end

let to_json = Json.package_to_json
let of_json = Json.package_of_json

(* Graph of cudf packages *)
module Package = struct
  type t = Cudf.package
  include Common.CudfAdd
  let to_string = string_of_package
  let name_to_string t = t.Cudf.package
  let version_to_string t = string_of_int t.Cudf.version
  let to_json = to_json
  let of_json = of_json
end

module Action = OpamActionGraph.MakeAction(Package)
module ActionGraph = OpamActionGraph.Make(Action)

let string_of_action = Action.to_string

let string_of_actions l =
  OpamStd.List.to_string (fun a -> " - " ^ string_of_action a) l

exception Solver_failure of string
exception Cyclic_actions of Action.t list list

type conflict_case =
  | Conflict_dep of (unit -> Algo.Diagnostic.reason list)
  | Conflict_cycle of string list list
type conflict =
  Cudf.universe * int package_map * conflict_case

module Map = OpamStd.Map.Make(Package)
module Set = OpamStd.Set.Make(Package)
module Graph = struct

  module PG = struct
    include Algo.Defaultgraphs.PackageGraph.G
    let succ g v =
      try succ g v
      with e -> OpamStd.Exn.fatal e; []
  end

  module PO = Algo.Defaultgraphs.GraphOper (PG)

  module Topo = Graph.Topological.Make (PG)

  let of_universe u =
    (* {[Algo.Defaultgraphs.PackageGraph.dependency_graph u]}
       -> doesn't handle conjunctive dependencies correctly
       (e.g. (a>3 & a<=4) is considered as (a>3 | a<=4) and results in extra
       edges).
       Here we handle the fact that a conjunction with the same pkgname is an
       intersection, while a conjunction between different names is an union *)
    let t = OpamConsole.timer () in
    let g = PG.create ~size:(Cudf.universe_size u) () in
    let iter_deps f deps =
      (* List.iter (fun d -> List.iter f (Common.CudfAdd.resolve_deps u d)) deps *)
      let strong_deps, weak_deps =
        (* strong deps are mandatory (constraint appearing in the top
           conjunction)
           weak deps correspond to optional occurrences of a package, as part of
           a disjunction: e.g. in (A>=4 & (B | A<5)), A>=4 is strong, and the
           other two are weak. In the end we want to retain B and A>=4. *)
        List.fold_left (fun (strong_deps, weak_deps) l ->
            let names =
              List.fold_left (fun acc (n, _) ->
                  OpamStd.String.Map.add n Set.empty acc)
                OpamStd.String.Map.empty l
            in
            let set =
              List.fold_left (fun acc (n, cstr) ->
                  List.fold_left (fun s x -> Set.add x s)
                    acc (Cudf.lookup_packages ~filter:cstr u n))
                Set.empty l
            in
            let by_name =
              Set.fold (fun p ->
                  OpamStd.String.Map.update
                    p.Cudf.package (Set.add p) Set.empty)
                set names
            in
            if OpamStd.String.Map.is_singleton by_name then
              let name, versions = OpamStd.String.Map.choose by_name in
              OpamStd.String.Map.update name (Set.inter versions) versions
                strong_deps,
              OpamStd.String.Map.remove name weak_deps
            else
              strong_deps, OpamStd.String.Map.union Set.union weak_deps by_name)
          (OpamStd.String.Map.empty, OpamStd.String.Map.empty) deps
      in
      OpamStd.String.Map.iter (fun _ p -> Set.iter f p) strong_deps;
      OpamStd.String.Map.iter (fun name p ->
          if not (OpamStd.String.Map.mem name strong_deps)
          then Set.iter f p)
        weak_deps
    in
    Cudf.iter_packages
      (fun p ->
         PG.add_vertex g p;
         iter_deps (PG.add_edge g p) p.Cudf.depends)
      u;
    log ~level:3 "Graph generation: %.3f" (t ());
    g

  let output g filename =
    let fd = open_out (filename ^ ".dot") in
    Algo.Defaultgraphs.PackageGraph.DotPrinter.output_graph fd g;
    close_out fd

  let transitive_closure g =
    PO.O.add_transitive_closure g

  let close_and_linearize g pkgs =
    let _, l =
      Topo.fold
        (fun pkg (closure, topo) ->
           if Set.mem pkg closure then
             closure, pkg :: topo
           else if List.exists (fun p -> Set.mem p closure) (PG.pred g pkg) then
             Set.add pkg closure, pkg :: topo
           else
             closure, topo)
        g
        (pkgs, []) in
    l

  let mirror = PO.O.mirror

  include PG
end

(** Special package used by Dose internally, should generally be filtered out *)
let dose_dummy_request = Algo.Depsolver.dummy_request.Cudf.package
let is_artefact cpkg =
  is_opam_invariant cpkg ||
  cpkg.Cudf.package = dose_dummy_request

let filter_dependencies f_direction universe packages =
  log ~level:3 "filter deps: build graph";
  let graph = f_direction (Graph.of_universe universe) in
  let packages = Set.of_list packages in
  log ~level:3 "filter deps: close_and_linearize";
  let r = Graph.close_and_linearize graph packages in
  log ~level:3 "filter deps: done";
  r

let dependencies = filter_dependencies (fun x -> x)
(* similar to Algo.Depsolver.dependency_closure but with finer results on
   version sets *)

let reverse_dependencies = filter_dependencies Graph.mirror
(* similar to Algo.Depsolver.reverse_dependency_closure but more reliable *)

let string_of_atom (p, c) =
  let const = function
    | None       -> ""
    | Some (r,v) -> Printf.sprintf " (%s %d)" (OpamPrinter.relop r) v in
  Printf.sprintf "%s%s" p (const c)

let string_of_vpkgs constr =
  let constr = List.sort (fun (a,_) (b,_) -> String.compare a b) constr in
  OpamFormula.string_of_conjunction string_of_atom constr

let string_of_universe u =
  string_of_packages (List.sort Common.CudfAdd.compare (Cudf.get_packages u))

let vpkg2atom cudfnv2opam (name,cstr) =
  match cstr with
  | None ->
    OpamPackage.Name.of_string (Common.CudfAdd.decode name), None
  | Some (relop,v) ->
    let nv = cudfnv2opam (name,v) in
    nv.name, Some (relop, nv.version)
(* Should be unneeded now that we pass a full version_map along
   [{
      log "Could not find corresponding version in cudf universe: %a"
        (slog string_of_atom) (name,cstr);
      let candidates =
        Cudf.lookup_packages cudf_universe name in
      let solutions =
        Cudf.lookup_packages ~filter:cstr cudf_universe name in
      let module OVS = OpamPackage.Version.Set in
      let to_version_set l =
        OVS.of_list
          (List.map (fun p -> OpamPackage.version (cudf2opam p)) l) in
      let solutions = to_version_set solutions in
      let others = OVS.Op.(to_version_set candidates -- solutions) in
      OpamPackage.Name.of_string (Common.CudfAdd.decode name),
      match relop, OVS.is_empty solutions, OVS.is_empty others with
      | _, true, true -> None
      | `Leq, false, _ | `Lt, false, true -> Some (`Leq, OVS.max_elt solutions)
      | `Lt, _, false | `Leq, true, false -> Some (`Lt, OVS.min_elt others)
      | `Geq, false, _ | `Gt, false, true -> Some (`Geq, OVS.min_elt solutions)
      | `Gt, _, false | `Geq, true, false -> Some (`Gt, OVS.max_elt others)
      | `Eq, false, _ -> Some (`Eq, OVS.choose solutions)
      | `Eq, true, _ ->
        Some (`Eq, OpamPackage.Version.of_string "<unavailable version>")
      | `Neq, false, true -> None
      | `Neq, _, false -> Some (`Neq, OVS.choose others)
   }]
*)

let vpkg2opam cudfnv2opam vpkg =
  match vpkg2atom cudfnv2opam vpkg with
  | p, None -> p, Empty
  | p, Some (relop,v) -> p, Atom (relop, v)

let conflict_empty ~version_map univ =
  Conflicts (univ, version_map, Conflict_dep (fun () -> []))
let make_conflicts ~version_map univ = function
  | {Algo.Diagnostic.result = Algo.Diagnostic.Failure f; _} ->
    Conflicts (univ, version_map, Conflict_dep f)
  | {Algo.Diagnostic.result = Algo.Diagnostic.Success _; _} ->
    raise (Invalid_argument "make_conflicts")
let cycle_conflict ~version_map univ cycle =
  Conflicts (univ, version_map, Conflict_cycle cycle)

let arrow_concat sl =
  let arrow =
    Printf.sprintf " %s "
      (OpamConsole.utf8_symbol OpamConsole.Symbols.rightwards_arrow "->")
  in
  String.concat (OpamConsole.colorise `yellow arrow) sl

let formula_of_vpkgl cudfnv2opam all_packages vpkgl =
  let atoms =
    List.map (fun vp ->
        try vpkg2atom cudfnv2opam vp
        with Not_found ->
          OpamPackage.Name.of_string (Common.CudfAdd.decode (fst vp)), None)
      vpkgl
  in
  let names = OpamStd.List.sort_nodup compare (List.map fst atoms) in
  let by_name =
    List.map (fun name ->
        let formula =
          OpamFormula.ors (List.map (function
              | n, Some atom when n = name -> Atom atom
              | _ -> Empty)
              atoms)
        in
        let all_versions = OpamPackage.versions_of_name all_packages name in
        let formula = OpamFormula.simplify_version_set all_versions formula in
        Atom (name, formula))
      names
  in
  OpamFormula.ors by_name

(* - Conflict message handling machinery - *)


let rec list_trunc n = function
  | x::r when n > 0 -> x :: list_trunc (n - 1) r
  | _ -> []

let list_cut n l =
  let rec aux acc n = function
    | x::r when n > 0 -> aux (x :: acc) (n-1) r
    | l -> acc, l
  in
  aux [] n l

let rec list_is_prefix pfx l = match pfx, l with
  | [], _ -> true
  | a::r1, b::r2 when a = b -> list_is_prefix r1 r2
  | _ -> false

(* chain sets: sets of package lists *)
module ChainSet = struct

  include OpamStd.Set.Make (struct
      type t = Package.t list
      let rec compare t1 t2 = match t1, t2 with
        | [], [] -> 0
        | [], _ -> -1
        | _, [] -> 1
        | p1::r1, p2::r2 ->
          match Package.compare p1 p2 with 0 -> compare r1 r2 | n -> n
      let to_string t =
        arrow_concat (List.rev_map Package.to_string t)
      let to_json t = Json.list_to_json Package.to_json t
      let of_json j = Json.list_of_json Package.of_json j
    end)

  (** Turns a set of lists into a list of sets *)
  let rec transpose cs =
    let hds, tls =
      fold (fun c (hds, tls) -> match c with
          | hd::tl -> Set.add hd hds, add tl tls
          | [] -> hds, tls)
        cs (Set.empty, empty)
    in
    if Set.is_empty hds then []
    else hds :: transpose tls

  let to_string_xx1 packages cs =
    let rec aux cs =
      let hds, tls =
        fold (fun c (hds, tls) -> match c with
            | hd::tl -> hd::hds, add tl tls
            | [] -> hds, tls)
          cs ([], empty)
      in
      if hds = [] then []
      else if List.exists is_artefact hds then
        if List.exists is_opam_invariant hds then "(invariant)" :: aux tls
        else aux tls
      else
      let nvs = OpamPackage.to_map (OpamPackage.Set.of_list (List.map cudf2opam hds)) in
      let strs =
        OpamPackage.Name.Map.mapi (fun name versions ->
            let all_versions = OpamPackage.versions_of_name packages name in
            let formula = OpamFormula.formula_of_version_set all_versions versions in
            OpamConsole.colorise' [`red;`bold]
              (OpamFormula.to_string (Atom (name, formula))))
          nvs
      in
      String.concat ", " (OpamPackage.Name.Map.values strs)
      :: aux tls
    in
    arrow_concat (aux (map List.rev cs))

  let to_string_raw cs =
    OpamStd.Format.itemize (fun chain ->
        arrow_concat (List.map Package.to_string chain))
      (elements cs)

  (** cs1 precludes cs2 if it contains a list that is prefix to all elements of
      cs2 *)
  let precludes cs1 cs2 =
    exists (fun pfx -> for_all (fun l -> list_is_prefix pfx l) cs2) cs1

  let length cs = fold (fun l acc -> min (List.length l) acc) cs max_int
end


let refact_cflt packages cudfnv2opam unav_reasons reasons =
  log "Conflict reporting";
  let open Algo.Diagnostic in
  let open Set.Op in
  let module CS = ChainSet in
  (* Definitions and printers *)
  let all_opam =
    let add p set =
      if is_artefact p then set
      else OpamPackage.Set.add (cudf2opam p) set
    in
    List.fold_left (fun acc -> function
        | Conflict (l, r, _) -> add l @@ add r @@ acc
        | Dependency (l, _, rs) ->
          List.fold_left (fun acc p -> add p acc) (add l acc) rs
        | Missing (p, _) -> add p acc)
      OpamPackage.Set.empty
      reasons
  in
  let print_set pkgs =
    if Set.exists is_artefact pkgs then
      if Set.exists is_opam_invariant pkgs then "(invariant)"
      else "(request)"
    else
    let nvs =
      OpamPackage.to_map @@
      Set.fold (fun p s -> OpamPackage.Set.add (cudf2opam p) s)
        pkgs OpamPackage.Set.empty
    in
    let strs =
      OpamPackage.Name.Map.mapi (fun name versions ->
          let all_versions = OpamPackage.versions_of_name all_opam name in
          let formula =
            OpamFormula.formula_of_version_set all_versions versions
          in
          OpamFormula.to_string (Atom (name, formula)))
        nvs
    in
    String.concat ", " (OpamPackage.Name.Map.values strs)
  in
  let cs_to_string cs =
    let rec aux vpkgl = function
      | [] -> []
      | pkgs :: r ->
        let vpkgl1 =
          List.fold_left (fun acc -> function
              | Dependency (p1, vpl, _) when Set.mem p1 pkgs ->
                List.rev_append vpl acc
              | _ -> acc)
            [] reasons
        in
        if Set.exists is_artefact pkgs then
          if Set.exists is_opam_invariant pkgs then
            Printf.sprintf "(invariant)"
            :: aux vpkgl1 r
          else aux vpkgl1 r (* request *)
        else if vpkgl = [] then
          print_set pkgs :: aux vpkgl1 r
        else
        let f =
          let vpkgl =
            List.filter
              (fun (n, _) -> Set.exists (fun p -> p.package = n) pkgs)
              vpkgl
          in
          formula_of_vpkgl cudfnv2opam packages vpkgl
        in
        OpamFormula.to_string f :: aux vpkgl1 r
    in
    arrow_concat (aux [] (CS.transpose (CS.map List.rev cs)))
  in
  let get t x = OpamStd.Option.default Set.empty (Hashtbl.find_opt t x) in
  let add_set t l set =
    match Hashtbl.find t l with
    | exception Not_found -> Hashtbl.add t l set
    | s -> Hashtbl.replace t l (Set.union set s)
  in
  (* Gather all data in hashtables *)
  let ct = Hashtbl.create 53 in
  let deps = Hashtbl.create 53 in
  let rdeps = Hashtbl.create 53 in
  let missing = Hashtbl.create 53 in
  List.iter (function
      | Conflict (l, r, _) ->
        add_set ct l (Set.singleton r);
        add_set ct r (Set.singleton l)
      | Dependency (l, _, rs) ->
        add_set deps l (Set.of_list rs);
        List.iter (fun r -> add_set rdeps r (Set.singleton l)) rs
      | Missing (p, deps) ->
        (* TODO check: add deps <-> p ? *)
        Hashtbl.add missing p deps)
    reasons;
  (* Get paths from the conflicts to requested or invariant packages *)
  let roots =
     Hashtbl.fold (fun p _ acc ->
        (* OpamConsole.errmsg "%s is_artefact %b\n" (Package.to_string p) (is_artefact p); *)
         if is_artefact p then Set.add p acc else acc)
       deps Set.empty
  in
  let conflicting =
    Hashtbl.fold (fun p _ -> Set.add p) ct Set.empty
  in
  let all_conflicting =
    Hashtbl.fold (fun k _ acc -> Set.add k acc) missing conflicting
  in
  (* let conflict_groups =
   *   (\* Gather packages by name, also separating version subset that trigger
   *      conflicts *\)
   *   let module NM = OpamStd.String.Map in (\* Cudf pkg name maps *\)
   *   let module VM = OpamStd.IntMap in (\* Cudf pkg version sets *\)
   *   let nvmlistmap =
   *     (\* name -> (version -> pkg map) list *\)
   *     Set.fold (fun p acc ->
   *         let package = p.Cudf.package in
   *         let version = p.Cudf.version in
   *         let in_conflict = get ct p in
   *         let rec add_v = function
   *           | [] -> [VM.singleton version p]
   *           | vm :: r ->
   *             if VM.exists (fun _ p1 -> Set.mem p1 in_conflict) vm
   *             then vm :: add_v r
   *             else VM.add version p vm :: r
   *         in
   *         let vmaps = try NM.find package acc with Not_found -> [] in
   *         NM.add package (add_v vmaps) acc)
   *       all_conflicting NM.empty
   *   in
   *   (\* Convert to pkg -> pkgset map *\)
   *   NM.fold (fun _ vml acc ->
   *       List.fold_left (fun acc vm ->
   *           let packages = VM.fold (fun _ p -> Set.add p) vm Set.empty in
   *           Set.fold (fun p -> Map.add p packages) packages acc)
   *         acc vml)
   *     nvmlistmap
   *     Map.empty
   * in *)
  let ct_chains =
    (* get a covering tree from the roots to all reachable packages.
       We keep only shortest chains, but all of them *)
    (* The chains are stored as lists from packages back to the roots *)
    let rec aux pchains seen acc =
      if Map.is_empty pchains then acc else
      let seen, new_chains =
        Map.fold (fun p chains (seen1, new_chains) ->
            let append_to_chains pkg acc =
              let chain = CS.map (fun c -> pkg :: c) chains in
              Map.update pkg (CS.union chain) CS.empty acc
            in
            let ds = get deps p in
            let dsc = ds %% all_conflicting in
            if not (Set.is_empty dsc) then
              dsc ++ seen1, Set.fold append_to_chains (dsc -- seen1) new_chains
            else
            Set.fold (fun d (seen1, new_chains) ->
                if Set.mem d seen then seen1, new_chains
                else Set.add d seen1, append_to_chains d new_chains)
              ds (seen1, new_chains))
          pchains (seen, Map.empty)
      in
      aux new_chains seen @@
      Map.union (fun _ _ -> assert false (*TODO: take the shortest*))
        pchains acc
    in
    let init_chains =
      Set.fold (fun p -> Map.add p (CS.singleton [p])) roots Map.empty
    in
    aux init_chains roots Map.empty
  in
  (* let root_chains =
   *   (\* Take only the chains that end on conflicts, and reverse them to get the
   *      root -> conflict path *\)
   *   Map.fold (fun p chains acc ->
   *       if Set.mem p roots then
   *         let rev_chains = CS.map List.rev chains in
   *         CS.fold (fun chain acc ->
   *             Map.update (List.hd chain) (CS.add chain) CS.empty acc)
   *           rev_chains acc
   *       else acc)
   *     ct_chains Map.empty
   * in *)
  (* X TODO order "reasons" by most interesting -> version conflicts then
     package then missing + shortest chains first (needed ?) *)

  let reasons =
    let clen p = try CS.length (Map.find p ct_chains) with Not_found -> 0 in
    let version_conflict =
      function Conflict (l, r, _) -> l.Cudf.package = r.Cudf.package | _ -> false
    in
    let cmp a b = match a, b with
      | Conflict (l1, r1, _), Conflict (l2, r2, _) ->
        let va = version_conflict a and vb = version_conflict b in
        if va && not vb then -1 else
        if vb && not va then 1 else
          (match compare (clen l1 + clen r1) (clen l2 + clen r2) with
           | 0 -> (match Package.compare l1 l2 with
               | 0 -> Package.compare r1 r2
               | n -> n)
           | n -> n)
      | _, Conflict _ -> 1
      | Conflict _, _ -> -1
      | Missing (p1, _), Missing (p2, _) ->
        (match compare (clen p1) (clen p2) with
         | 0 -> Package.compare p1 p2
         | n -> n)
      | _, Missing _ -> 1
      | Missing _, _ -> -1
      | Dependency _, Dependency _ -> 0 (* we don't care anymore *)
    in
    List.sort_uniq cmp reasons
  in

  (* let ct_chains =
   *   List.fold_left (fun acc c ->
   *       match c with
   *       | Conflict (l, r, _) ->
   *         (try
   *            let cl = Map.find l ct_chains in
   *            let cr = Map.find r ct_chains in
   *            CS.Map. cl c (CS.Map.add cr c *)

  let _seen_chains =
    List.fold_left (fun ct_chains re ->
        let cst ct_chains p =
          let chains = Map.find p ct_chains in
          Map.filter (fun _ c -> not (CS.precludes chains c)) ct_chains,
          cs_to_string chains
        in
        match re with
        | Conflict (l, r, _) when l.Cudf.package = r.Cudf.package ->
          (try
             let ct_chains, csl = cst ct_chains l in
             let ct_chains, csr = cst ct_chains r in
             Printf.eprintf "VERSION CONFLICT: No agreement on the version of %s:\n\t%s\n\t%s\n"
               (Package.name_to_string l) csl csr;
             ct_chains
           with Not_found -> ct_chains)
        | Conflict (l, r, _) ->
          (try
             let ct_chains, csl = cst ct_chains l in
             let ct_chains, csr = cst ct_chains r in
             Printf.eprintf "PACKAGE CONFLICT:\n\t%s\n\t%s\n" csl csr;
             ct_chains
           with Not_found -> ct_chains)
        | Missing (p, _) ->
          (try
             let ct_chains, csp = cst ct_chains p in
             Printf.eprintf "MISSING: %s\n\t%s\n" (Package.to_string p) (csp);
             ct_chains
           with Not_found -> ct_chains)
        | Dependency _ -> ct_chains)
      ct_chains reasons
  in
  ()

let strings_of_reasons packages cudfnv2opam unav_reasons rs =
  let open Algo.Diagnostic in
  let rec aux = function
    | [] -> []
    | Conflict (i,j,jc)::rs ->
      if is_artefact i || is_artefact j then
        let a = if is_artefact i then j else i in
        if is_artefact a then aux rs else
        let str =
          Printf.sprintf "Conflicting query for package %s"
            (OpamPackage.to_string (cudf2opam a)) in
        str :: aux rs
      else if i.Cudf.package = j.Cudf.package then
        let str = Printf.sprintf "No available version of %s satisfies the \
                                  constraints"
            (OpamPackage.name_to_string (cudf2opam i)) in
        str :: aux rs
      else
      let nva = cudf2opam i in
      let versions, rs =
        List.fold_left (fun (versions, rs) -> function
            | Conflict (i1, _, jc1) when
                (cudf2opam i1).name = nva.name && jc1 = jc ->
              OpamPackage.Version.Set.add (cudf2opam i1).version versions, rs
            | Conflict (_, i2, (_, cstr)) when
                (cudf2opam i2).name = nva.name && Cudf.(|=) i.version cstr ->
              OpamPackage.Version.Set.add (cudf2opam i2).version versions, rs
            | r -> versions, r::rs)
          (OpamPackage.Version.Set.singleton nva.version, []) rs
      in
      let rs = List.rev rs in
      let formula =
        OpamFormula.formula_of_version_set
          (OpamPackage.versions_of_name packages nva.name) versions
      in
      let str = Printf.sprintf "%s is in conflict with %s"
          (OpamFormula.to_string (Atom (nva.name, formula)))
          (OpamFormula.to_string
             (OpamFormula.of_atom_formula (Atom (vpkg2atom cudfnv2opam jc))))
      in
      str :: aux rs
    | Missing (p,missing) :: rs when is_artefact p ->
      (* Requested pkg missing *)
      let atoms =
        List.map (fun vp ->
            try vpkg2atom cudfnv2opam vp
            with Not_found ->
              OpamPackage.Name.of_string (Common.CudfAdd.decode (fst vp)), None)
          missing
      in
      let names = OpamStd.List.sort_nodup compare (List.map fst atoms) in
      List.map (fun name ->
          let formula =
            OpamFormula.ors (List.map (function
                | n, Some atom when n = name -> Atom atom
                | _ -> Empty)
                atoms)
          in
          let all_versions = OpamPackage.versions_of_name packages name in
          let formula = OpamFormula.simplify_version_set all_versions formula in
          OpamConsole.colorise' [`red;`bold]
            (OpamFormula.to_string (Atom (name, formula)))
          ^": "^
          unav_reasons (name, formula))
        names @
      aux rs
    | Missing _ :: rs (* dependency missing, treated in strings_of_chains *)
    | Dependency _ :: rs -> aux rs
  in
  aux rs


let make_chains packages cudfnv2opam depends =
  let open Algo.Diagnostic in
  let map_addlist k v map =
    try Map.add k (v @ Map.find k map) map
    with Not_found -> Map.add k v map in
  let roots,_cflct,deps,vpkgs =
    List.fold_left (fun (roots,cflct,deps,vpkgs) -> function
        | Dependency (i, vpkgl, jl) ->
          Set.add i roots,
          cflct,
          map_addlist i jl deps,
          map_addlist i vpkgl vpkgs
        | Missing (i, vpkgl) when not (is_artefact i) ->
          let jl =
            List.map (fun (package,_) ->
                {Cudf.default_package with Cudf.package})
              vpkgl in
          Set.add i roots,
          cflct,
          map_addlist i jl deps,
          map_addlist i vpkgl vpkgs
        | Conflict (i1, i2, _) when i1.Cudf.package = i2.Cudf.package ->
          roots,
          OpamStd.String.Set.add i1.Cudf.package cflct,
          deps,
          vpkgs
        | _ -> roots, cflct, deps, vpkgs)
      (Set.empty,OpamStd.String.Set.empty,Map.empty,Map.empty)
      depends
  in
  if Set.is_empty roots then [] else
  let children cpkgs =
    Set.fold (fun c acc ->
        (* if OpamStd.String.Set.mem c.Cudf.package cflct then acc else *)
        List.fold_left (fun m a -> Set.add a m) acc
          (try Map.find c deps with Not_found -> []))
      cpkgs Set.empty
  in
  let rec aux constrs direct_deps =
    if Set.is_empty direct_deps then [[]] else
    let depnames =
      Set.fold (fun p set -> OpamStd.String.Set.add p.Cudf.package set)
        direct_deps OpamStd.String.Set.empty in
    OpamStd.String.Set.fold (fun name acc ->
        let name_deps = (* Gather all deps with the given name *)
          Set.filter (fun p -> p.Cudf.package = name) direct_deps in
        let name_constrs =
          List.map (List.filter (fun (n,_) -> n = name)) constrs in
        let formula =
          if name = opam_invariant_package_name then None else
          let to_opam_constr p =
            snd (vpkg2opam cudfnv2opam p)
          in
          let formula =
            OpamFormula.ors
              (List.map (fun conj ->
                   OpamFormula.ands (List.map to_opam_constr conj))
                  name_constrs)
          in
          let opam_name =
            OpamPackage.Name.of_string (Common.CudfAdd.decode name)
          in
          let all_versions = OpamPackage.versions_of_name packages opam_name in
          let formula = OpamFormula.simplify_version_set all_versions formula in
          Some (opam_name, formula)
        in
        let children_constrs =
          List.map (fun p ->
              (* if OpamStd.String.Set.mem p.Cudf.package cflct then []
               * (\* don't dig into deeper conflicts *\)
               * else *) try Map.find p vpkgs with Not_found -> [])
            (Set.elements name_deps) in
        let chains = aux children_constrs (children name_deps) in
        List.fold_left
          (fun acc chain -> (formula :: chain) :: acc)
          acc chains
      )
      depnames []
  in
  let roots = Set.filter is_artefact roots in
  let start_constrs =
      List.map (fun v -> try Map.find v vpkgs with Not_found -> [])
        (Set.elements roots)
  in
  List.fold_left (fun acc chain -> match chain with
      | [] | [_] | [_;_] -> acc
      | _ :: chain -> chain :: acc)
    []
    (aux start_constrs roots)

let strings_of_final_reasons packages cudfnv2opam unav_reasons reasons =
  let reasons =
    strings_of_reasons packages cudfnv2opam unav_reasons reasons
  in
  OpamStd.List.sort_nodup compare reasons

let strings_of_chains packages cudfnv2opam unav_reasons reasons =
  let chains = make_chains packages cudfnv2opam reasons in
  let chains = List.map List.rev chains in
  let string_of_chain = function
    | None :: _ -> assert false (* no package can depend on the invariant *)
    | Some (name, vform) :: r ->
      let all_versions = OpamPackage.versions_of_name packages name in
      let formula = OpamFormula.simplify_version_set all_versions vform in
      String.concat "" [
        OpamConsole.colorise' [`red;`bold]
          (OpamFormula.to_string (Atom (name, vform)));
        (match r with | [] -> "" | r ->
            Printf.sprintf " (from %s)" @@
            arrow_concat
              (List.rev_map (function
                   | Some c -> OpamFormula.to_string (Atom c)
                   | None -> "The switch invariant") r));
        (match unav_reasons (name, formula) with "" -> "" | s -> "\n  " ^ s);
      ]
    | [] -> ""
  in
  let chains =
    let rec cmp l1 l2 =
      match l1, l2 with
      | None::r1, None::r2 -> cmp r1 r2
      | None::_, _ -> -1
      | _, None::_ -> 1
      | Some a1::r1, Some a2::r2 ->
        let c = OpamFormula.compare_nc a1 a2 in
        if c <> 0 then c else cmp r1 r2
      | [], _::_ -> -1
      | _::_, [] -> 1
      | [], [] -> 0
    in
    List.sort cmp chains
  in
  List.map string_of_chain chains

let strings_of_cycles cycles =
  List.map arrow_concat cycles

let strings_of_conflict packages unav_reasons = function
  | univ, version_map, Conflict_dep reasons ->
    let r = reasons () in
    let cudfnv2opam = cudfnv2opam ~cudf_universe:univ ~version_map in
    refact_cflt packages cudfnv2opam unav_reasons r;
    strings_of_final_reasons packages cudfnv2opam unav_reasons r,
    strings_of_chains packages cudfnv2opam unav_reasons r,
    []
  | _univ, _version_map, Conflict_cycle cycles ->
    [], [], strings_of_cycles cycles

let conflict_chains packages = function
  | cudf_universe, version_map, Conflict_dep r ->
    make_chains packages (cudfnv2opam ~cudf_universe ~version_map) (r ())
  | _ -> []

let string_of_conflict packages unav_reasons conflict =
  let final, chains, cycles =
    strings_of_conflict packages unav_reasons conflict
  in
  let b = Buffer.create 1024 in
  let pr_items b l =
    Buffer.add_string b (OpamStd.Format.itemize (fun s -> s) l)
  in
  if cycles <> [] then
    Printf.bprintf b
      "The actions to process have cyclic dependencies:\n%a"
      pr_items cycles;
  if chains <> [] then
    Printf.bprintf b
      "The following dependencies couldn't be met:\n%a"
      pr_items chains;
  if final <> [] then
    Printf.bprintf b
      "Your request can't be satisfied:\n%a"
      pr_items final;
  if final = [] && chains = [] && cycles = [] then (* No explanation found *)
    Printf.bprintf b
      "Sorry, no solution found: \
       there seems to be a problem with your request.\n";
  Buffer.add_string b "\n";
  Buffer.contents b

let check flag p =
  try Cudf.lookup_typed_package_property p flag = `Bool true
  with Not_found -> false

let need_reinstall = check s_reinstall

(*
let is_installed_root = check s_installed_root

let is_pinned = check s_pinned
*)

let default_preamble =
  let l = [
    (s_source,         `String None);
    (s_source_number,  `String None);
    (s_reinstall,      `Bool (Some false));
    (s_installed_root, `Bool (Some false));
    (s_pinned,         `Bool (Some false));
    (s_version_lag,    `Nat (Some 0));
  ] in
  Common.CudfAdd.add_properties Cudf.default_preamble l

let remove universe name constr =
  let filter p =
    p.Cudf.package <> name
    || not (Cudf.version_matches p.Cudf.version constr) in
  let packages = Cudf.get_packages ~filter universe in
  Cudf.load_universe packages

let uninstall_all universe =
  let packages = Cudf.get_packages universe in
  let packages = List.rev_map (fun p -> { p with Cudf.installed = false }) packages in
  Cudf.load_universe packages

let install universe package =
  let p = Cudf.lookup_package universe (package.Cudf.package, package.Cudf.version) in
  let p = { p with Cudf.installed = true } in
  let packages =
    let filter p =
      p.Cudf.package <> package.Cudf.package
      || p.Cudf.version <> package.Cudf.version in
    Cudf.get_packages ~filter universe in
  Cudf.load_universe (p :: packages)

let remove_all_uninstalled_versions_but universe name constr =
  let filter p =
    p.Cudf.installed
    || p.Cudf.package <> name
    || Cudf.version_matches p.Cudf.version constr in
  let packages = Cudf.get_packages ~filter universe in
  Cudf.load_universe packages

let to_cudf univ req = (
  Common.CudfAdd.add_properties default_preamble
    (List.map (fun s -> s, `Int (Some 0)) req.extra_attributes),
  univ,
  { Cudf.request_id = "opam";
    install         = req.wish_install;
    remove          = req.wish_remove;
    upgrade         = req.wish_upgrade;
    req_extra       = [] }
)



let string_of_request r =
  Printf.sprintf "install:%s remove:%s upgrade:%s"
    (string_of_vpkgs r.wish_install)
    (string_of_vpkgs r.wish_remove)
    (string_of_vpkgs r.wish_upgrade)

let solver_calls = ref 0

let dump_universe oc univ =
  Cudf_printer.pp_cudf oc
    (default_preamble, univ, Cudf.default_request)

let dump_cudf_request ~version_map (_, univ,_ as cudf) criteria =
  function
  | None   -> None
  | Some f ->
    ignore ( version_map: int OpamPackage.Map.t );
    incr solver_calls;
    let filename = Printf.sprintf "%s-%d.cudf" f !solver_calls in
    let oc = open_out filename in
    let module Solver = (val OpamSolverConfig.(Lazy.force !r.solver)) in
    Printf.fprintf oc "# Solver: %s\n"
      (OpamCudfSolver.get_name (module Solver));
    Printf.fprintf oc "# Criteria: %s\n" criteria;
    Cudf_printer.pp_cudf oc cudf;
    OpamPackage.Map.iter (fun (pkg:OpamPackage.t) (vnum: int) ->
      let name = OpamPackage.name_to_string pkg in
      let version = OpamPackage.version_to_string pkg in
      Printf.fprintf oc "#v2v:%s:%d=%s\n" name vnum version;
    ) version_map;
    close_out oc;
    Graph.output (Graph.of_universe univ) f;
    Some filename

let dump_cudf_error ~version_map univ req =
  let cudf_file = match OpamSolverConfig.(!r.cudf_file) with
    | Some f -> f
    | None ->
      let (/) = Filename.concat in
      OpamCoreConfig.(!r.log_dir) /
      ("solver-error-"^string_of_int (OpamStubs.getpid())) in
  match
    dump_cudf_request (to_cudf univ req) ~version_map
      (OpamSolverConfig.criteria req.criteria)
      (Some cudf_file)
  with
  | Some f -> f
  | None -> assert false

exception Timeout of Algo.Depsolver.solver_result option

let call_external_solver ~version_map univ req =
  let cudf_request = to_cudf univ req in
  if Cudf.universe_size univ > 0 then
    let criteria = OpamSolverConfig.criteria req.criteria in
    let chrono = OpamConsole.timer () in
    ignore (dump_cudf_request ~version_map cudf_request
              criteria OpamSolverConfig.(!r.cudf_file));
    (* Wrap a return of exn Timeout through Depsolver *)
    let check_request_using ~call_solver ~criteria ~explain req =
      let timed_out = ref false in
      let call_solver args =
        try call_solver args with
        | OpamCudfSolver.Timeout (Some s) -> timed_out := true; s
        | OpamCudfSolver.Timeout None -> raise (Timeout None)
      in
      let r =
        Algo.Depsolver.check_request_using ~call_solver ~criteria ~explain req
      in
      if !timed_out then raise (Timeout (Some r)) else r
    in
    try
      let r =
        check_request_using
          ~call_solver:(OpamSolverConfig.call_solver ~criteria)
          ~criteria ~explain:true cudf_request
      in
      log "Solver call done in %.3fs" (chrono ());
      r
    with
    | Timeout (Some sol) ->
      log "Solver call TIMED OUT with solution after %.3fs" (chrono ());
      OpamConsole.warning
        "Resolution of the installation set timed out, so the following \
         solution might not be optimal.\n\
         You may want to make your request more precise, increase the value \
         of OPAMSOLVERTIMEOUT (currently %.1fs), or try a different solver."
        OpamSolverConfig.(OpamStd.Option.default 0. !r.solver_timeout);
      sol
    | Timeout None ->
      let msg =
        Printf.sprintf
          "Sorry, resolution of the request timed out.\n\
           Try to specify a more precise request, use a different solver, or \
           increase the allowed time by setting OPAMSOLVERTIMEOUT to a bigger \
           value (currently, it is set to %.1f seconds)."
          OpamSolverConfig.(OpamStd.Option.default 0. !r.solver_timeout)
      in
      raise (Solver_failure msg)
    | Failure msg ->
      let msg =
        Printf.sprintf
          "Solver failure: %s\nThis may be due to bad settings (solver or \
           solver criteria) or a broken solver solver installation. Check \
           $OPAMROOT/config, and the --solver and --criteria options."
          msg
      in
      raise (Solver_failure msg)
    | e ->
      OpamStd.Exn.fatal e;
      let msg =
        Printf.sprintf "Solver failed: %s" (Printexc.to_string e)
      in
      raise (Solver_failure msg)
  else
    Algo.Depsolver.Sat(None,Cudf.load_universe [])

let check_request ?(explain=true) ~version_map univ req =
  match Algo.Depsolver.check_request ~explain (to_cudf univ req) with
  | Algo.Depsolver.Unsat
      (Some ({Algo.Diagnostic.result = Algo.Diagnostic.Failure _; _} as r)) ->
    make_conflicts ~version_map univ r
  | Algo.Depsolver.Sat (_,u) ->
    Success (remove u dose_dummy_request None)
  | Algo.Depsolver.Error msg ->
    let f = dump_cudf_error ~version_map univ req in
    let msg =
      Printf.sprintf "Internal solver failed with %s Request saved to %S"
        msg f
    in
    raise (Solver_failure msg)
  | Algo.Depsolver.Unsat _ -> (* normally when [explain] = false *)
    conflict_empty ~version_map univ

(* Return the universe in which the system has to go *)
let get_final_universe ~version_map univ req =
  let fail msg =
    let f = dump_cudf_error ~version_map univ req in
    let msg =
      Printf.sprintf "External solver failed with %s Request saved to %S"
        msg f
    in
    raise (Solver_failure msg) in
  match call_external_solver ~version_map univ req with
  | Algo.Depsolver.Sat (_,u) -> Success (remove u dose_dummy_request None)
  | Algo.Depsolver.Error "(CRASH) Solution file is empty" ->
    (* XXX Is this still needed with latest dose? *)
    Success (Cudf.load_universe [])
  | Algo.Depsolver.Error str -> fail str
  | Algo.Depsolver.Unsat r   ->
    OpamConsole.error
      "The solver (%s) pretends there is no solution while that's apparently \
       false.\n\
       This is likely an issue with the solver interface, please try a \
       different solver and report if you were using a supported one."
      (let module Solver = (val OpamSolverConfig.(Lazy.force !r.solver)) in
       Solver.name);
    match r with
    | Some ({Algo.Diagnostic.result = Algo.Diagnostic.Failure _; _} as r) ->
      make_conflicts ~version_map univ r
    | Some {Algo.Diagnostic.result = Algo.Diagnostic.Success _; _}
    | None ->
      raise (Solver_failure
        "The current solver could not find a solution but dose3 could. \
         This is probably a bug in the current solver. Please file a bug-report \
         on the opam bug tracker: https://github.com/ocaml/opam/issues/")

let diff univ sol =
  let before =
    Set.of_list
      (Cudf.get_packages ~filter:(fun p -> p.Cudf.installed) univ)
  in
  let after =
    Set.of_list
      (Cudf.get_packages ~filter:(fun p -> p.Cudf.installed) sol)
  in
  let open Set.Op in
  let reinstall = Set.filter need_reinstall after in
  let install = after -- before ++ reinstall in
  let remove = before -- after ++ reinstall in
  install, remove

(* Transform a diff from current to final state into a list of
   actions. At this point, we don't know about the root causes of the
   actions, they will be computed later. *)
let actions_of_diff (install, remove) =
  let actions = [] in
  let actions = Set.fold (fun p acc -> `Install p :: acc) install actions in
  let actions = Set.fold (fun p acc -> `Remove p :: acc) remove actions in
  actions

let resolve ~extern ~version_map universe request =
  log "resolve request=%a" (slog string_of_request) request;
  let resp =
    match check_request ~version_map universe request with
    | Success _ when extern -> get_final_universe ~version_map universe request
    | resp -> resp
  in
  let cleanup univ =
    Cudf.remove_package univ opam_invariant_package
  in
  let () = match resp with
    | Success univ -> cleanup univ
    | Conflicts (univ, _, _) -> cleanup univ
  in
  resp

let to_actions f universe result =
  let aux u1 u2 =
    let diff = diff (f u1) u2 in
    actions_of_diff diff
  in
  map_success (aux universe) result

let create_graph filter universe =
  let pkgs = Cudf.get_packages ~filter universe in
  let u = Cudf.load_universe pkgs in
  Graph.of_universe u

let find_cycles g =
  let open ActionGraph in
  let roots =
    fold_vertex (fun v acc -> if in_degree g v = 0 then v::acc else acc) g [] in
  let roots =
    if roots = [] then fold_vertex (fun v acc -> v::acc) g []
    else roots in
  let rec prefix_find acc v = function
    | x::_ when x = v -> Some (x::acc)
    | x::r -> prefix_find (x::acc) v r
    | [] -> None in
  let seen = Hashtbl.create 17 in
  let rec follow v path =
    match prefix_find [] v path with
    | Some cycle ->
      Hashtbl.add seen v ();
      [cycle@[v]]
    | None ->
      if Hashtbl.mem seen v then [] else
        let path = v::path in
        Hashtbl.add seen v ();
        List.fold_left (fun acc s -> follow s path @ acc) []
          (succ g v) in
  List.fold_left (fun cycles root ->
    follow root [] @ cycles
  ) [] roots

(* Compute the original causes of the actions, from the original set of
   packages in the user request. In the restricted dependency graph, for each
   action we find the closest package belonging to the user request and print
   out the closest neighbour that gets there. This way, if a -> b -> c and the
   user requests a to be installed, we can print:
   - install a - install b [required by a] - intall c [required by b] *)
let compute_root_causes g requested reinstall =
  let module StringSet = OpamStd.String.Set in
  let requested_pkgnames =
    OpamPackage.Name.Set.fold (fun n s ->
        StringSet.add (Common.CudfAdd.encode (OpamPackage.Name.to_string n)) s)
      requested StringSet.empty in
  let reinstall_pkgnames =
    OpamPackage.Set.fold (fun nv s ->
        StringSet.add (Common.CudfAdd.encode (OpamPackage.name_to_string nv)) s)
      reinstall StringSet.empty in
  let actions =
    ActionGraph.fold_vertex (fun a acc -> Map.add (action_contents a) a acc)
      g Map.empty in
  let requested_actions =
    Map.filter (fun pkg _ ->
        StringSet.mem pkg.Cudf.package requested_pkgnames)
      actions in
  let merge_causes (c1,depth1) (c2,depth2) =
    (* When we found several causes explaining the same action, only keep the
       most likely one *)
    if c2 = Unknown || depth1 < depth2 then c1, depth1 else
    if c1 = Unknown || depth2 < depth1 then c2, depth2 else
    let (@) =
      List.fold_left (fun l a -> if List.mem a l then l else a::l)
    in
    match c1, c2 with
    | Required_by a, Required_by b -> Required_by (a @ b), depth1
    | Use a, Use b -> Use (a @ b), depth1
    | Conflicts_with a, Conflicts_with b -> Conflicts_with (a @ b), depth1
    | Requested, a | a, Requested
    | Unknown, a | a, Unknown
    | Upstream_changes , a | a, Upstream_changes -> a, depth1
    | _, c -> c, depth1
  in
  let direct_cause consequence order cause =
    (* Investigate the reason of action [consequence], that was possibly
       triggered by [cause], where the actions are ordered as [consequence]
       [order] [cause]. *)
    match consequence, order, cause with
    | (`Install _ | `Change _), `Before, (`Install p | `Change (_,_,p)) ->
      (* Prerequisite *)
      Required_by [p]
    | `Change _, `After, (`Install p | `Change (_,_,p)) ->
      (* Change caused by change in dependencies *)
      Use [p]
    | `Reinstall _, `After, a ->
      (* Reinstall caused by action on deps *)
      Use [action_contents a]
    | (`Remove _ | `Change _ ), `Before, `Remove p ->
      (* Removal or change caused by the removal of a dependency *)
      Use [p]
    | `Remove _, `Before, (`Install p | `Change (_,_,p) | `Reinstall p) ->
      (* Removal caused by conflict *)
      Conflicts_with [p]
    | (`Install _ | `Change _), `Before, `Reinstall p ->
      (* New dependency of p? *)
      Required_by [p]
    | `Change _, _, _ ->
      (* The only remaining cause for changes is upstream *)
      Upstream_changes
    | (`Install _ | `Remove _), `After, _  ->
      (* Nothing can cause these actions after itself *)
      Unknown
    | (`Install _ | `Reinstall _), `Before, _ ->
      (* An install or reinstall doesn't cause any other actions on its
         dependendants *)
      Unknown
    | `Build _, _, _ | _, _, `Build _ -> assert false
    | `Fetch _, _, _ | _, _, `Fetch _ -> assert false (* XXX CHECK *)
  in
  let get_causes acc roots =
    let rec aux seen depth pkgname causes =
      if depth > 100 then
        (OpamConsole.error
           "Internal error computing action causes: sorry, please report.";
         causes)
      else
      let action = Map.find pkgname actions in
      let seen = Set.add pkgname seen in
      let propagate causes actions direction =
        List.fold_left (fun causes act ->
            let p = action_contents act in
            if Set.mem p seen then causes else
            let cause = direct_cause act direction action in
            if cause = Unknown then causes else
            try
              Map.add p (merge_causes (cause,depth) (Map.find p causes)) causes
            with Not_found ->
              aux seen (depth + 1) p (Map.add p (cause,depth) causes)
          ) causes actions in
      let causes = propagate causes (ActionGraph.pred g action) `Before in
      let causes = propagate causes (ActionGraph.succ g action) `After in
      causes
    in
    let start = Map.fold (fun k _ acc -> Set.add k acc) roots Set.empty in
    let acc = Map.union (fun a _ -> a) acc roots in
    Set.fold (aux start 1) start acc
  in
  (* Compute the roots of the action given a condition *)
  let make_roots causes base_cause f =
    ActionGraph.fold_vertex (fun act acc ->
        if Map.mem (action_contents act) causes then acc else
        if f act then Map.add (action_contents act) (base_cause,0) acc else
          acc)
      g Map.empty in
  let causes = Map.empty in
  let causes =
    let roots =
      if Map.is_empty requested_actions then (* Assume a global upgrade *)
        make_roots causes Requested (function
            | `Change (`Up,_,_) -> true
            | _ -> false)
      else (Map.map (fun _ -> Requested, 0) requested_actions) in
    get_causes causes roots in
  let causes =
    (* Compute causes for remaining upgrades
       (maybe these could be removed from the actions altogether since they are
       unrelated to the request?) *)
    let roots = make_roots causes Unknown (function
        | `Change _ as act ->
          List.for_all
            (function `Change _ -> false | _ -> true)
            (ActionGraph.pred g act)
        | _ -> false) in
    get_causes causes roots in
  let causes =
    (* Compute causes for marked reinstalls *)
    let roots =
      make_roots causes Upstream_changes (function
          | `Reinstall p ->
            (* need_reinstall p is not available here *)
            StringSet.mem p.Cudf.package reinstall_pkgnames
          | _ -> false)
    in
    get_causes causes roots in
  Map.map fst causes

(* Compute a full solution from a set of root actions. This means adding all
   required reinstallations and computing the graph of dependency of required
   actions *)
let atomic_actions ~simple_universe ~complete_universe root_actions =
  log "graph_of_actions root_actions=%a"
    (slog string_of_actions) root_actions;

  let to_remove, to_install =
    List.fold_left (fun (rm,inst) a -> match a with
        | `Change (_,p1,p2) ->
          Set.add p1 rm, Set.add p2 inst
        | `Install p -> rm, Set.add p inst
        | `Reinstall p -> Set.add p rm, Set.add p inst
        | `Remove p -> Set.add p rm, inst)
      (Set.empty, Set.empty) root_actions in

  (* transitively add recompilations *)
  let to_remove, to_install =
    let packages = Set.union to_remove to_install in
    let package_graph =
      let filter p = p.Cudf.installed || Set.mem p packages in
      Graph.mirror (create_graph filter simple_universe)
    in
    Graph.Topo.fold (fun p (rm,inst) ->
        let actionned p = Set.mem p rm || Set.mem p inst in
        if not (actionned p) &&
           List.exists actionned (Graph.pred package_graph p)
        then Set.add p rm, Set.add p inst
        else rm, inst)
      package_graph (to_remove, to_install)
  in
  let pkggraph set = create_graph (fun p -> Set.mem p set) complete_universe in

  (* Build the graph of atomic actions: Removals or installs *)
  let g = ActionGraph.create () in
  Set.iter (fun p -> ActionGraph.add_vertex g (`Remove p)) to_remove;
  Set.iter (fun p -> ActionGraph.add_vertex g (`Install (p))) to_install;
  (* reinstalls and upgrades: remove first *)
  Set.iter
    (fun p1 ->
       try
         let p2 =
           Set.find (fun p2 -> p1.Cudf.package = p2.Cudf.package) to_install
         in
         ActionGraph.add_edge g (`Remove p1) (`Install (p2))
       with Not_found -> ())
    to_remove;
  (* uninstall order *)
  Graph.iter_edges (fun p1 p2 ->
      ActionGraph.add_edge g (`Remove p1) (`Remove p2)
    ) (pkggraph to_remove);
  (* install order *)
  Graph.iter_edges (fun p1 p2 ->
      if Set.mem p1 to_install then
        let cause =
          if Set.mem p2 to_install then `Install ( p2) else `Remove p2
        in
        ActionGraph.add_edge g cause (`Install ( p1))
    ) (pkggraph (Set.union to_install to_remove));
  (* conflicts *)
  let conflicts_graph =
    let filter p = Set.mem p to_remove || Set.mem p to_install in
    Algo.Defaultgraphs.PackageGraph.conflict_graph
      (Cudf.load_universe (Cudf.get_packages ~filter complete_universe))
  in
  Algo.Defaultgraphs.PackageGraph.UG.iter_edges (fun p1 p2 ->
      if Set.mem p1 to_remove && Set.mem p2 to_install then
        ActionGraph.add_edge g (`Remove p1) (`Install ( p2))
      else if Set.mem p2 to_remove && Set.mem p1 to_install then
        ActionGraph.add_edge g (`Remove p2) (`Install ( p1)))
    conflicts_graph;
  (* check for cycles *)
  match find_cycles g with
  | [] -> g
  | cycles -> raise (Cyclic_actions cycles)

let packages u = Cudf.get_packages u
