%%%-------------------------------------------------------------------
%%% @copyright (C) 2018, Aeternity Anstalt
%%% @doc
%%%     Type checker for Sophia.
%%% @end
%%%-------------------------------------------------------------------

%%% All state is kept in a set of ETS tables. These are NOT named
%%% tables and the table ids are kept in process dictionary in a map
%%% under the key 'aeso_ast_infer_types'. This allows multiple
%%% instances of the compiler to be run in parallel.

-module(aeso_ast_infer_types).

-export([infer/1, infer/2, infer_constant/1]).

-type utype() :: {fun_t, aeso_syntax:ann(), named_args_t(), [utype()], utype()}
               | {app_t, aeso_syntax:ann(), utype(), [utype()]}
               | {tuple_t, aeso_syntax:ann(), [utype()]}
               | aeso_syntax:id()  | aeso_syntax:qid()
               | aeso_syntax:con() | aeso_syntax:qcon()  %% contracts
               | aeso_syntax:tvar()
               | uvar().

-type uvar() :: {uvar, aeso_syntax:ann(), reference()}.

-type named_args_t() :: uvar() | [{named_arg_t, aeso_syntax:ann(), aeso_syntax:id(), utype(), aeso_syntax:expr()}].

-type type_id() :: aeso_syntax:id() | aeso_syntax:qid() | aeso_syntax:con() | aeso_syntax:qcon().

-define(is_type_id(T), element(1, T) =:= id orelse
                       element(1, T) =:= qid orelse
                       element(1, T) =:= con orelse
                       element(1, T) =:= qcon).

-type why_record() :: aeso_syntax:field(aeso_syntax:expr())
                    | {proj, aeso_syntax:ann(), aeso_syntax:expr(), aeso_syntax:id()}.

-record(named_argument_constraint,
    {args :: named_args_t(),
     name :: aeso_syntax:id(),
     type :: utype()}).

-type named_argument_constraint() :: #named_argument_constraint{}.

-record(field_constraint,
    { record_t :: utype()
    , field    :: aeso_syntax:id()
    , field_t  :: utype()
    , kind     :: project | create | update %% Projection constraints can match contract
    , context  :: why_record() }).          %% types, but field constraints only record types.

%% Constraint checking that 'record_t' has precisely 'fields'.
-record(record_create_constraint,
    { record_t :: utype()
    , fields   :: [aeso_syntax:id()]
    , context  :: why_record() }).

-type field_constraint() :: #field_constraint{} | #record_create_constraint{}.

-record(field_info,
    { ann      :: aeso_syntax:ann()
    , field_t  :: utype()
    , record_t :: utype()
    , kind     :: contract | record }).

-type field_info() :: #field_info{}.

-type access() :: public | private | internal.

-type typedef() :: {[aeso_syntax:tvar()], aeso_syntax:type_def() | {contract_t, [aeso_syntax:field_t()]}}
                 | {builtin, non_neg_integer()}.

-type type() :: aeso_syntax:type().
-type name() :: string().
-type qname() :: [string()].
-type typesig() :: {type_sig, aeso_syntax:ann(), [aeso_syntax:named_arg_t()], [type()], type()}.

-type fun_info()  :: {aeso_syntax:ann(), typesig() | type()}.
-type type_info() :: {aeso_syntax:ann(), typedef()}.
-type var_info()  :: {aeso_syntax:ann(), type()}.

-type fun_env()  :: [{name(), fun_info()}].
-type type_env() :: [{name(), type_info()}].

-record(scope, { funs   = [] :: fun_env()
               , types  = [] :: type_env()
               , access = public :: access()
               , kind   = namespace :: namespace | contract
               , ann    = [{origin, system}] :: aeso_syntax:ann()
               }).

-type scope() :: #scope{}.

-record(env,
    { scopes    = #{ [] => #scope{}} :: #{ qname() => scope() }
    , vars      = []                 :: [{name(), var_info()}]
    , fields    = #{}                :: #{ name() => [field_info()] }    %% fields are global
    , namespace = []                 :: qname()
    }).

-type env() :: #env{}.

-define(PRINT_TYPES(Fmt, Args),
        when_option(pp_types, fun () -> io:format(Fmt, Args) end)).

%% -- Environment manipulation -----------------------------------------------

-spec push_scope(namespace | contract, aeso_syntax:con(), env()) -> env().
push_scope(Kind, Con, Env) ->
    Ann  = aeso_syntax:get_ann(Con),
    Name = name(Con),
    New  = Env#env.namespace ++ [Name],
    Env#env{ namespace = New, scopes = (Env#env.scopes)#{ New => #scope{ kind = Kind, ann = Ann } } }.

-spec pop_scope(env()) -> env().
pop_scope(Env) ->
    Env#env{ namespace = lists:droplast(Env#env.namespace) }.

-spec get_scope(env(), qname()) -> false | scope().
get_scope(#env{ scopes = Scopes }, Name) ->
    maps:get(Name, Scopes, false).

-spec on_current_scope(env(), fun((scope()) -> scope())) -> env().
on_current_scope(Env = #env{ namespace = NS, scopes = Scopes }, Fun) ->
    Scope = maps:get(NS, Scopes),
    Env#env{ scopes = Scopes#{ NS => Fun(Scope) } }.

-spec bind_var(aeso_syntax:id(), type(), env()) -> env().
bind_var({id, Ann, X}, T, Env) ->
    Env#env{ vars = [{X, {Ann, T}} | Env#env.vars] }.

-spec bind_vars([{aeso_syntax:id(), type()}], env()) -> env().
bind_vars([], Env) -> Env;
bind_vars([{X, T} | Vars], Env) ->
    bind_vars(Vars, bind_var(X, T, Env)).

-spec bind_fun(name(), type() | typesig(), env()) -> env().
bind_fun(X, Type, Env) ->
    Ann = aeso_syntax:get_ann(Type),
    case lookup_name(Env, [X]) of
        false ->
            on_current_scope(Env, fun(Scope = #scope{ funs = Funs }) ->
                                    Scope#scope{ funs = [{X, {Ann, Type}} | Funs] }
                                  end);
        {_QId, {Ann1, _}} ->
            type_error({duplicate_definition, X, [Ann1, Ann]}),
            Env
    end.

-spec bind_funs([{name(), type() | typesig()}], env()) -> env().
bind_funs([], Env) -> Env;
bind_funs([{Id, Type} | Rest], Env) ->
    bind_funs(Rest, bind_fun(Id, Type, Env)).

-spec bind_type(name(), aeso_syntax:ann(), typedef(), env()) -> env().
bind_type(X, Ann, Def, Env) ->
    on_current_scope(Env, fun(Scope = #scope{ types = Types }) ->
                            Scope#scope{ types = [{X, {Ann, Def}} | Types] }
                          end).

-spec bind_field(name(), field_info(), env()) -> env().
bind_field(X, Info, Env = #env{ fields = Fields }) ->
    Fields1 = maps:update_with(X, fun(Infos) -> [Info | Infos] end, [Info], Fields),
    Env#env{ fields = Fields1 }.

-spec bind_fields([{name(), field_info()}], env()) -> env().
bind_fields([], Env) -> Env;
bind_fields([{Id, Info} | Rest], Env) ->
    bind_fields(Rest, bind_field(Id, Info, Env)).

%% Contract entrypoints take two named arguments (gas : int = Call.gas_left(), value : int = 0).
contract_call_type({fun_t, Ann, [], Args, Ret}) ->
    Id    = fun(X) -> {id, Ann, X} end,
    Int   = Id("int"),
    Typed = fun(E, T) -> {typed, Ann, E, T} end,
    Named = fun(Name, Default) -> {named_arg_t, Ann, Id(Name), Int, Default} end,
    {fun_t, Ann, [Named("gas",   Typed({app, Ann, Typed({qid, Ann, ["Call", "gas_left"]},
                                                        {fun_t, Ann, [], [], Int}),
                                        []}, Int)),
                  Named("value", Typed({int, Ann, 0}, Int))], Args, Ret}.

-spec bind_contract(aeso_syntax:decl(), env()) -> env().
bind_contract({contract, Ann, Id, Contents}, Env) ->
    Key    = name(Id),
    Sys    = [{origin, system}],
    Fields = [ {field_t, AnnF, Entrypoint, contract_call_type(Type)}
                || {fun_decl, AnnF, Entrypoint, Type} <- Contents ] ++
              %% Predefined fields
             [ {field_t, Sys, {id, Sys, "address"}, {id, Sys, "address"}} ],
    FieldInfo = [ {Entrypoint, #field_info{ kind     = contract,
                                            field_t  = Type,
                                            record_t = Id }}
                || {field_t, _, {id, _, Entrypoint}, Type} <- Fields ],
    bind_type(Key, Ann, {[], {contract_t, Fields}},
        bind_fields(FieldInfo, Env)).

%% What scopes could a given name come from?
-spec possible_scopes(env(), qname()) -> [qname()].
possible_scopes(#env{ namespace = Current}, Name) ->
    Qual = lists:droplast(Name),
    [ lists:sublist(Current, I) ++ Qual || I <- lists:seq(0, length(Current)) ].

-spec lookup_name(env(), qname()) -> false | {qname(), fun_info()}.
lookup_name(Env, Name) ->
    lookup_env(Env, term, Name).

-spec lookup_type(env(), type_id()) -> false | {qname(), type_info()}.
lookup_type(Env, Id) ->
    case lookup_env(Env, type, qname(Id)) of
        false       -> false;
        {QId, Type} -> {QId, unfold_types_in_type(Env, push_anns(Id, Type))}
    end.

-spec lookup_env(env(), term, qname()) -> false | {qname(), fun_info()};
                (env(), type, qname()) -> false | {qname(), type_info()}.
lookup_env(Env, Kind, Name) ->
    Var = case Name of
            [X] when Kind == term -> proplists:get_value(X, Env#env.vars, false);
            _                     -> false
          end,
    case Var of
        {Ann, Type} -> {Name, {Ann, Type}};
        false ->
            Names = [ Qual ++ [lists:last(Name)] || Qual <- possible_scopes(Env, Name) ],
            case [ Res || QName <- Names, Res <- [lookup_env1(Env, Kind, QName)], Res /= false] of
                []    -> false;
                [Res] -> Res;
                Many  -> type_error({ambiguous_name, [{qid, Ann, Q} || {Q, {Ann, _}} <- Many]})
            end
    end.

-spec lookup_env1(env(), type | term, qname()) -> false | {qname(), fun_info()}.
lookup_env1(#env{ namespace = Current, scopes = Scopes }, Kind, QName) ->
    Qual = lists:droplast(QName),
    Name = lists:last(QName),
    AllowPrivate = lists:prefix(Qual, Current),
    %% Get the scope
    case maps:get(Qual, Scopes, false) of
        false -> false; %% TODO: return reason for not in scope
        #scope{ funs = Funs, types = Types } ->
            Defs = case Kind of
                     type -> Types;
                     term -> Funs
                   end,
            %% Look up the unqualified name
            case proplists:get_value(Name, Defs, false) of
                false -> false;
                {Ann, _} = E ->
                    %% Check that it's not private (or we can see private funs)
                    case not is_private(Ann) orelse AllowPrivate of
                        true  -> {QName, E};
                        false -> false
                    end
            end
    end.

-spec lookup_record_field(env(), name()) -> [field_info()].
lookup_record_field(Env, FieldName) ->
    maps:get(FieldName, Env#env.fields, []).

%% For 'create' or 'update' constraints we don't consider contract types.
-spec lookup_record_field(env(), name(), contract | record) -> [field_info()].
lookup_record_field(Env, FieldName, Kind) ->
    [ Fld || Fld = #field_info{ kind = K } <- lookup_record_field(Env, FieldName),
             Kind == project orelse K /= contract ].

%% -- Name manipulation ------------------------------------------------------

-spec qname(type_id()) -> qname().
qname({id,   _, X})  -> [X];
qname({qid,  _, Xs}) -> Xs;
qname({con,  _, X})  -> [X];
qname({qcon, _, Xs}) -> Xs.

-spec name(aeso_syntax:id() | aeso_syntax:con()) -> name().
name({_, _, X}) -> X.

-spec qid(aeso_syntax:ann(), qname()) -> aeso_syntax:id() | aeso_syntax:qid().
qid(Ann, [X]) -> {id, Ann, X};
qid(Ann, Xs)  -> {qid, Ann, Xs}.

-spec qcon(aeso_syntax:ann(), qname()) -> aeso_syntax:con() | aeso_syntax:qcon().
qcon(Ann, [X]) -> {con, Ann, X};
qcon(Ann, Xs)  -> {qcon, Ann, Xs}.

-spec set_qname(qname(), type_id()) -> type_id().
set_qname(Xs, {id,   Ann, _}) -> qid(Ann, Xs);
set_qname(Xs, {qid,  Ann, _}) -> qid(Ann, Xs);
set_qname(Xs, {con,  Ann, _}) -> qcon(Ann, Xs);
set_qname(Xs, {qcon, Ann, _}) -> qcon(Ann, Xs).

is_private(Ann) -> proplists:get_value(private, Ann, false).

%% -- The rest ---------------------------------------------------------------

%% Environment containing language primitives
-spec global_env() -> env().
global_env() ->
    Ann     = [{origin, system}],
    Int     = {id, Ann, "int"},
    Bool    = {id, Ann, "bool"},
    String  = {id, Ann, "string"},
    Address = {id, Ann, "address"},
    Event   = {id, Ann, "event"},
    State   = {id, Ann, "state"},
    Hash    = {id, Ann, "hash"},
    Bits    = {id, Ann, "bits"},
    Oracle  = fun(Q, R) -> {app_t, Ann, {id, Ann, "oracle"}, [Q, R]} end,
    Query   = fun(Q, R) -> {app_t, Ann, {id, Ann, "oracle_query"}, [Q, R]} end,
    Unit    = {tuple_t, Ann, []},
    List    = fun(T) -> {app_t, Ann, {id, Ann, "list"}, [T]} end,
    Option  = fun(T) -> {app_t, Ann, {id, Ann, "option"}, [T]} end,
    Map     = fun(A, B) -> {app_t, Ann, {id, Ann, "map"}, [A, B]} end,
    Pair    = fun(A, B) -> {tuple_t, Ann, [A, B]} end,
    Fun     = fun(Ts, T) -> {type_sig, Ann, [], Ts, T} end,
    Fun1    = fun(S, T) -> Fun([S], T) end,
    TVar    = fun(X) -> {tvar, Ann, "'" ++ X} end,
    SignId    = {id, Ann, "signature"},
    SignDef   = {tuple, Ann, [{int, Ann, 0}, {int, Ann, 0}]},
    Signature = {named_arg_t, Ann, SignId, SignId, {typed, Ann, SignDef, SignId}},
    SignFun   = fun(Ts, T) -> {type_sig, Ann, [Signature], Ts, T} end,
    TTL       = {qid, Ann, ["Chain", "ttl"]},
    Fee       = Int,
    [A, Q, R, K, V] = lists:map(TVar, ["a", "q", "r", "k", "v"]),

    MkDefs = fun(Defs) -> [{X, {Ann, if is_integer(T) -> {builtin, T}; true -> T end}} || {X, T} <- Defs] end,

    TopScope = #scope
        { funs  = MkDefs(
                     %% Option constructors
                    [{"None", Option(A)},
                     {"Some", Fun1(A, Option(A))},
                     %% TTL constructors
                     {"RelativeTTL", Fun1(Int, TTL)},
                     {"FixedTTL",    Fun1(Int, TTL)},
                     %% State
                     {"state", State},
                     {"put",   Fun1(State, Unit)},
                     %% Abort
                     {"abort", Fun1(String, A)}])
        , types = MkDefs(
                    [{"int", 0}, {"bool", 0}, {"string", 0}, {"address", 0},
                     {"hash", 0}, {"signature", 0}, {"bits", 0},
                     {"option", 1}, {"list", 1}, {"map", 2},
                     {"oracle", 2}, {"oracle_query", 2}
                     ]) },

    ChainScope = #scope
        { funs = MkDefs(
                     %% Spend transaction.
                    [{"spend",        Fun([Address, Int], Unit)},
                     %% Chain environment
                     {"balance",      Fun1(Address, Int)},
                     {"block_hash",   Fun1(Int, Int)},
                     {"coinbase",     Address},
                     {"timestamp",    Int},
                     {"block_height", Int},
                     {"difficulty",   Int},
                     {"gas_limit",    Int},
                     {"event",        Fun1(Event, Unit)}])
        , types = MkDefs([{"TTL", 0}]) },

    ContractScope = #scope
        { funs = MkDefs(
                    [{"address", Address},
                     %% {"owner",   Int},    %% Not in EVM
                     {"balance", Int}]) },

    CallScope = #scope
        { funs = MkDefs(
                    [{"origin",    Address},
                     {"caller",    Address},
                     {"value",     Int},
                     {"gas_price", Int},
                     {"gas_left",  Fun([], Int)}])
        },

    OracleScope = #scope
        { funs = MkDefs(
                    [{"register",     SignFun([Address, Fee, TTL], Oracle(Q, R))},
                     {"query_fee",    Fun([Oracle(Q, R)], Fee)},
                     {"query",        Fun([Oracle(Q, R), Q, Fee, TTL, TTL], Query(Q, R))},
                     {"get_question", Fun([Oracle(Q, R), Query(Q, R)], Q)},
                     {"respond",      SignFun([Oracle(Q, R), Query(Q, R), R], Unit)},
                     {"extend",       SignFun([Oracle(Q, R), TTL], Unit)},
                     {"get_answer",   Fun([Oracle(Q, R), Query(Q, R)], option_t(Ann, R))}]) },

    AENSScope = #scope
        { funs = MkDefs(
                     [{"resolve",  Fun([String, String], option_t(Ann, A))},
                      {"preclaim", SignFun([Address, Hash], Unit)},
                      {"claim",    SignFun([Address, String, Int], Unit)},
                      {"transfer", SignFun([Address, Address, Hash], Unit)},
                      {"revoke",   SignFun([Address, Hash], Unit)}]) },

    MapScope = #scope
        { funs = MkDefs(
                     [{"from_list",      Fun1(List(Pair(K, V)), Map(K, V))},
                      {"to_list",        Fun1(Map(K, V), List(Pair(K, V)))},
                      {"lookup",         Fun([K, Map(K, V)], Option(V))},
                      {"lookup_default", Fun([K, Map(K, V), V], V)},
                      {"delete",         Fun([K, Map(K, V)], Map(K, V))},
                      {"member",         Fun([K, Map(K, V)], Bool)},
                      {"size",           Fun1(Map(K, V), Int)}]) },

    %% Crypto/Curve operations
    CryptoScope = #scope
        { funs = MkDefs(
                     [{"ecverify", Fun([Hash, Address, SignId], Bool)},
                      {"sha3",     Fun1(A, Hash)},
                      {"sha256",   Fun1(A, Hash)},
                      {"blake2b",  Fun1(A, Hash)}]) },

     %% Strings
     StringScope = #scope
        { funs = MkDefs(
                     [{"length",  Fun1(String, Int)},
                      {"concat",  Fun([String, String], String)},
                      {"sha3",    Fun1(String, Hash)},
                      {"sha256",  Fun1(String, Hash)},
                      {"blake2b", Fun1(String, Hash)}]) },

     %% Bits
     BitsScope = #scope
        { funs = MkDefs(
                     [{"set",          Fun([Bits, Int], Bits)},
                      {"clear",        Fun([Bits, Int], Bits)},
                      {"test",         Fun([Bits, Int], Bool)},
                      {"sum",          Fun1(Bits, Int)},
                      {"intersection", Fun([Bits, Bits], Bits)},
                      {"union",        Fun([Bits, Bits], Bits)},
                      {"difference",   Fun([Bits, Bits], Bits)},
                      {"none",         Bits},
                      {"all",          Bits}]) },

     %% Conversion
     IntScope     = #scope{ funs = MkDefs([{"to_str", Fun1(Int,     String)}]) },
     AddressScope = #scope{ funs = MkDefs([{"to_str", Fun1(Address, String)}]) },

    #env{ scopes =
            #{ []           => TopScope
             , ["Chain"]    => ChainScope
             , ["Contract"] => ContractScope
             , ["Call"]     => CallScope
             , ["Oracle"]   => OracleScope
             , ["AENS"]     => AENSScope
             , ["Map"]      => MapScope
             , ["Crypto"]   => CryptoScope
             , ["String"]   => StringScope
             , ["Bits"]     => BitsScope
             , ["Int"]      => IntScope
             , ["Address"]  => AddressScope
             } }.

option_t(As, T) -> {app_t, As, {id, As, "option"}, [T]}.
map_t(As, K, V) -> {app_t, As, {id, As, "map"}, [K, V]}.

-spec infer(aeso_syntax:ast()) -> aeso_syntax:ast().
infer(Contracts) ->
    infer(Contracts, []).

-type option() :: permissive_address_literals.

-spec init_env(list(option())) -> env().
init_env(Options) ->
    case proplists:get_value(permissive_address_literals, Options, false) of
        false -> global_env();
        true ->
            %% Treat oracle and query ids as address to allow address literals for these
            Ann = [{origin, system}],
            Tag = fun(Tag, Val) -> {Tag, Ann, Val} end,
            lists:foldl(fun({Name, Arity}, E) ->
                            bind_type(Name, [{origin, system}],
                                {lists:duplicate(Arity, Tag(tvar, "_")),
                                    {alias_t, Tag(id, "address")}}, E)
                        end, global_env(), [{"oracle", 2}, {"oracle_query", 2}])
    end.

-spec infer(aeso_syntax:ast(), list(option())) -> aeso_syntax:ast().
infer(Contracts, Options) ->
    ets_init(), %% Init the ETS table state
    try
        Env = init_env(Options),
        create_options(Options),
        ets_new(type_vars, [set]),
        infer1(Env, Contracts, [])
    after
        clean_up_ets()
    end.

-spec infer1(env(), [aeso_syntax:decl()], [aeso_syntax:decl()]) -> [aeso_syntax:decl()].
infer1(_, [], Acc) -> lists:reverse(Acc);
infer1(Env, [Contract = {contract, Ann, ConName, Code} | Rest], Acc) ->
    %% do type inference on each contract independently.
    check_scope_name_clash(Env, contract, ConName),
    {Env1, Code1} = infer_contract_top(push_scope(contract, ConName, Env), Code),
    Contract1 = {contract, Ann, ConName, Code1},
    Env2 = pop_scope(Env1),
    Env3 = bind_contract(Contract, Env2),
    infer1(Env3, Rest, [Contract1 | Acc]);
infer1(Env, [{namespace, Ann, Name, Code} | Rest], Acc) ->
    check_scope_name_clash(Env, namespace, Name),
    {Env1, Code1} = infer_contract_top(push_scope(namespace, Name, Env), Code),
    Namespace1 = {namespace, Ann, Name, Code1},
    infer1(pop_scope(Env1), Rest, [Namespace1 | Acc]).

check_scope_name_clash(Env, Kind, Name) ->
    case get_scope(Env, qname(Name)) of
        false -> ok;
        #scope{ kind = K, ann = Ann } ->
            create_type_errors(),
            type_error({duplicate_scope, Kind, Name, K, Ann}),
            destroy_and_report_type_errors()
    end.

-spec infer_contract_top(env(), [aeso_syntax:decl()]) -> {env(), [aeso_syntax:decl()]}.
infer_contract_top(Env, Defs0) ->
    Defs = desugar(Defs0),
    {Env1, Defs1} = infer_contract(Env, Defs),
    Env2  = on_current_scope(Env1, fun(Scope) -> unfold_record_types(Env1, Scope) end),
    Defs2 = unfold_record_types(Env2, Defs1),
    {Env2, Defs2}.

%% TODO: revisit
infer_constant({letval, Attrs,_Pattern, Type, E}) ->
    ets_init(), %% Init the ETS table state
    {typed, _, _, PatType} =
        infer_expr(global_env(), {typed, Attrs, E, arg_type(Type)}),
    instantiate(PatType).

%% infer_contract takes a proplist mapping global names to types, and
%% a list of definitions.
-spec infer_contract(env(), [aeso_syntax:decl()]) -> {env(), [aeso_syntax:decl()]}.
infer_contract(Env, Defs) ->
    Kind = fun({type_def, _, _, _, _})  -> type;
              ({letfun, _, _, _, _, _}) -> function;
              ({fun_decl, _, _, _})     -> prototype
           end,
    Get = fun(K) -> [ Def || Def <- Defs, Kind(Def) == K ] end,
    {Env1, TypeDefs} = check_typedefs(Env, Get(type)),
    ProtoSigs = [ check_fundecl(Env1, Decl) || Decl <- Get(prototype) ],
    create_type_errors(),
    Env2      = bind_funs(ProtoSigs, Env1),
    Functions = Get(function),
    %% Check for duplicates in Functions (we turn it into a map below)
    _         = bind_funs([{Fun, {tuple_t, Ann, []}} || {letfun, Ann, {id, _, Fun}, _, _, _} <- Functions],
                          #env{}),
    FunMap    = maps:from_list([ {Fun, Def} || Def = {letfun, _, {id, _, Fun}, _, _, _} <- Functions ]),
    check_reserved_entrypoints(FunMap),
    DepGraph  = maps:map(fun(_, Def) -> aeso_syntax_utils:used_ids(Def) end, FunMap),
    SCCs      = aeso_utils:scc(DepGraph),
    %% io:format("Dependency sorted functions:\n  ~p\n", [SCCs]),
    {Env3, Defs1} = check_sccs(Env2, FunMap, SCCs, []),
    destroy_and_report_type_errors(),
    {Env3, TypeDefs ++ Defs1}.

-spec check_typedefs(env(), [aeso_syntax:decl()]) -> {env(), [aeso_syntax:decl()]}.
check_typedefs(Env, Defs) ->
    create_type_errors(),
    GetName  = fun({type_def, _, {id, _, Name}, _, _}) -> Name end,
    TypeMap  = maps:from_list([ {GetName(Def), Def} || Def <- Defs ]),
    DepGraph = maps:map(fun(_, Def) -> aeso_syntax_utils:used_types(Def) end, TypeMap),
    SCCs     = aeso_utils:scc(DepGraph),
    %% io:format("Dependency sorted types:\n  ~p\n", [SCCs]),
    Env1     = check_typedef_sccs(Env, TypeMap, SCCs),
    destroy_and_report_type_errors(),
    SCCNames = fun({cyclic, Xs}) -> Xs; ({acyclic, X}) -> [X] end,
    {Env1, [ Def || SCC <- SCCs, Name <- SCCNames(SCC),
                    Def <- [maps:get(Name, TypeMap, undefined)], Def /= undefined ]}.

-spec check_typedef_sccs(env(), #{ name() => aeso_syntax:decl() }, [{acyclic, name()} | {cyclic, [name()]}]) ->
        env().
check_typedef_sccs(Env, _TypeMap, []) -> Env;
check_typedef_sccs(Env, TypeMap, [{acyclic, Name} | SCCs]) ->
    case maps:get(Name, TypeMap, undefined) of
        undefined -> check_typedef_sccs(Env, TypeMap, SCCs);    %% Builtin type
        {type_def, Ann, D, Xs, Def} ->
            Env1 = bind_type(Name, Ann, {Xs, Def}, Env),
            case Def of
                {alias_t, _}  -> check_typedef_sccs(Env1, TypeMap, SCCs); %% TODO: check these
                {record_t, Fields} ->
                    RecTy = app_t(Ann, D, Xs),
                    Env2 = check_fields(Env1, TypeMap, RecTy, Fields),
                    check_typedef_sccs(Env2, TypeMap, SCCs);
                {variant_t, Cons} ->
                    Target   = app_t(Ann, D, Xs),
                    ConType  = fun([]) -> Target; (Args) -> {type_sig, Ann, [], Args, Target} end,
                    ConTypes = [ begin
                                    {constr_t, _, {con, _, Con}, Args} = ConDef,
                                    {Con, ConType(Args)}
                                 end || ConDef <- Cons ],
                    check_repeated_constructors([ {Con, ConType(Args)} || {constr_t, _, Con, Args} <- Cons ]),
                    [ check_constructor_overlap(Env1, Con, Target) || {constr_t, _, Con, _} <- Cons ],
                    [ check_event(Cons) || Name == "event" ],
                    check_typedef_sccs(bind_funs(ConTypes, Env1), TypeMap, SCCs)
            end
    end;
check_typedef_sccs(Env, TypeMap, [{cyclic, Names} | SCCs]) ->
    Id = fun(X) -> {type_def, _, D, _, _} = maps:get(X, TypeMap), D end,
    type_error({recursive_types_not_implemented, lists:map(Id, Names)}),
    check_typedef_sccs(Env, TypeMap, SCCs).

-spec check_fields(env(), #{ name() => aeso_syntax:decl() }, type(), [aeso_syntax:field_t()]) -> env().
check_fields(Env, _TypeMap, _, []) -> Env;
check_fields(Env, TypeMap, RecTy, [{field_t, Ann, Id, Type} | Fields]) ->
    Env1 = bind_field(name(Id), #field_info{ ann = Ann, kind = record, field_t = Type, record_t = RecTy }, Env),
    check_fields(Env1, TypeMap, RecTy, Fields).

check_event(Cons) ->
    [ check_event(Name, Types) || {constr_t, _, {con, _, Name}, Types} <- Cons ].

%% Initially we limit the type of an event, it can have 0-3 topics/indexed "words"
%% and 0-1 strings as payload.
check_event(Name, Types) ->
    IsIndexed  = fun(T) -> aeso_syntax:get_ann(indexed, T, false) end,
    Indexed    = [ T || T <- Types, IsIndexed(T) ],
    NonIndexed = Types -- Indexed,
    %% TODO: Is is possible to check also the types of arguments in a sensible way?
    [ type_error({event_0_to_3_indexed_values, Name}) || length(Indexed) > 3 ],
    [ type_error({event_0_to_1_string_values, Name}) || length(NonIndexed) > 1 ].

-spec check_constructor_overlap(env(), aeso_syntax:con(), type()) -> ok | no_return().
check_constructor_overlap(Env, Con = {con, _, Name}, NewType) ->
    case lookup_name(Env, Name) of
        false -> ok;
        {_, {Ann, Type}} ->
            OldType = case Type of {type_sig, _, _, _, T} -> T;
                                   _ -> Type end,
            OldCon  = {con, Ann, Name},
            type_error({repeated_constructor, [{OldCon, OldType}, {Con, NewType}]})
    end.

check_repeated_constructors(Cons) ->
    Names      = [ Name || {{con, _, Name}, _} <- Cons ],
    Duplicated = lists:usort(Names -- lists:usort(Names)),
    Fail       = fun(Name) ->
                    type_error({repeated_constructor, [ CT || CT = {{con, _, C}, _} <- Cons, C == Name ]})
                 end,
    [ Fail(Dup) || Dup <- Duplicated ],
    ok.

-spec check_sccs(env(), #{ name() => aeso_syntax:decl() }, [{acyclic, name()} | {cyclic, [name()]}], [aeso_syntax:decl()]) ->
        {env(), [aeso_syntax:decl()]}.
check_sccs(Env, _, [], Acc) -> {Env, lists:reverse(Acc)};
check_sccs(Env = #env{}, Funs, [{acyclic, X} | SCCs], Acc) ->
    case maps:get(X, Funs, undefined) of
        undefined ->    %% Previously defined function
            check_sccs(Env, Funs, SCCs, Acc);
        Def ->
            {{_, TypeSig}, Def1} = infer_nonrec(Env, Def),
            Env1 = bind_fun(X, TypeSig, Env),
            check_sccs(Env1, Funs, SCCs, [Def1 | Acc])
    end;
check_sccs(Env = #env{}, Funs, [{cyclic, Xs} | SCCs], Acc) ->
    Defs = [ maps:get(X, Funs) || X <- Xs ],
    {TypeSigs, {letrec, _, Defs1}} = infer_letrec(Env, {letrec, [], Defs}),
    Env1 = bind_funs(TypeSigs, Env),
    check_sccs(Env1, Funs, SCCs, Defs1 ++ Acc).

check_reserved_entrypoints(Funs) ->
    Reserved = ["address"],
    _ = [ type_error({reserved_entrypoint, Name, Def})
            || {Name, Def} <- maps:to_list(Funs), lists:member(Name, Reserved) ],
    ok.

-spec check_fundecl(env(), aeso_syntax:decl()) -> {name(), typesig()}.
check_fundecl(_Env, {fun_decl, Ann, {id, _, Name}, {fun_t, _, Named, Args, Ret}}) ->
    {Name, {type_sig, Ann, Named, Args, Ret}};  %% TODO: actually check that the type makes sense!
check_fundecl(_, {fun_decl, _Attrib, {id, _, Name}, Type}) ->
    error({fundecl_must_have_funtype, Name, Type}).

infer_nonrec(Env, LetFun) ->
    create_constraints(),
    NewLetFun = infer_letfun(Env, LetFun),
    check_special_funs(Env, NewLetFun),
    solve_constraints(Env),
    destroy_and_report_unsolved_constraints(Env),
    Result = {TypeSig, _} = instantiate(NewLetFun),
    print_typesig(TypeSig),
    Result.

%% Currenty only the init function.
check_special_funs(Env, {{"init", Type}, _}) ->
    {type_sig, Ann, _Named, _Args, Res} = Type,
    State =
        %% We might have implicit (no) state.
        case lookup_type(Env, {id, [], "state"}) of
            false -> {tuple_t, [{origin, system}], []};
            _     -> {id, [{origin, system}], "state"}
        end,
    unify(Env, Res, State, {checking_init_type, Ann});
check_special_funs(_, _) -> ok.

typesig_to_fun_t({type_sig, Ann, Named, Args, Res}) -> {fun_t, Ann, Named, Args, Res}.

infer_letrec(Env, {letrec, Attrs, Defs}) ->
    create_constraints(),
    Funs = [{Name, fresh_uvar(A)}
                 || {letfun, _, {id, A, Name}, _, _, _} <- Defs],
    ExtendEnv = bind_funs(Funs, Env),
    Inferred =
        [ begin
            Res    = {{Name, TypeSig}, _} = infer_letfun(ExtendEnv, LF),
            Got    = proplists:get_value(Name, Funs),
            Expect = typesig_to_fun_t(TypeSig),
            unify(Env, Got, Expect, {check_typesig, Name, Got, Expect}),
            solve_field_constraints(Env),
            ?PRINT_TYPES("Checked ~s : ~s\n",
                         [Name, pp(dereference_deep(Got))]),
            Res
          end || LF <- Defs ],
    destroy_and_report_unsolved_constraints(Env),
    TypeSigs = instantiate([Sig || {Sig, _} <- Inferred]),
    NewDefs  = instantiate([D || {_, D} <- Inferred]),
    [print_typesig(S) || S <- TypeSigs],
    {TypeSigs, {letrec, Attrs, NewDefs}}.

infer_letfun(Env, {letfun, Attrib, {id, NameAttrib, Name}, Args, What, Body}) ->
    ArgTypes  = [{ArgName, arg_type(T)} || {arg, _, ArgName, T} <- Args],
    ExpectedType = arg_type(What),
    NewBody={typed, _, _, ResultType} = check_expr(bind_vars(ArgTypes, Env), Body, ExpectedType),
    NewArgs = [{arg, A1, {id, A2, ArgName}, T}
               || {{_, T}, {arg, A1, {id, A2, ArgName}, _}} <- lists:zip(ArgTypes, Args)],
    NamedArgs = [],
    TypeSig = {type_sig, Attrib, NamedArgs, [T || {arg, _, _, T} <- NewArgs], ResultType},
    {{Name, TypeSig},
     {letfun, Attrib, {id, NameAttrib, Name}, NewArgs, ResultType, NewBody}}.

print_typesig({Name, TypeSig}) ->
    ?PRINT_TYPES("Inferred ~s : ~s\n", [Name, pp(TypeSig)]).

arg_type({id, Attrs, "_"}) ->
    fresh_uvar(Attrs);
arg_type({app_t, Attrs, Name, Args}) ->
    {app_t, Attrs, Name, [arg_type(T) || T <- Args]};
arg_type(T) ->
    T.

app_t(_Ann, Name, [])  -> Name;
app_t(Ann, Name, Args) -> {app_t, Ann, Name, Args}.

lookup_name(Env, As, Name) ->
    lookup_name(Env, As, Name, []).

lookup_name(Env, As, Id, Options) ->
    case lookup_name(Env, qname(Id)) of
        false ->
            type_error({unbound_variable, Id}),
            {Id, fresh_uvar(As)};
        {QId, {_, Ty}} ->
            Freshen = proplists:get_value(freshen, Options, false),
            Ty1 = case Ty of
                    {type_sig, _, _, _, _} -> freshen_type(typesig_to_fun_t(Ty));
                    _ when Freshen         -> freshen_type(Ty);
                    _                      -> Ty
                  end,
            {set_qname(QId, Id), Ty1}
    end.

check_expr(Env, Expr, Type) ->
    E = {typed, _, _, Type1} = infer_expr(Env, Expr),
    unify(Env, Type1, Type, {check_expr, Expr, Type1, Type}),
    E.

infer_expr(_Env, Body={bool, As, _}) ->
    {typed, As, Body, {id, As, "bool"}};
infer_expr(_Env, Body={int, As, _}) ->
    {typed, As, Body, {id, As, "int"}};
infer_expr(_Env, Body={string, As, _}) ->
    {typed, As, Body, {id, As, "string"}};
infer_expr(_Env, Body={hash, As, Hash}) ->
    case byte_size(Hash) of
        32 -> {typed, As, Body, {id, As, "address"}};
        64 -> {typed, As, Body, {id, As, "signature"}}
    end;
infer_expr(_Env, Body={id, As, "_"}) ->
    {typed, As, Body, fresh_uvar(As)};
infer_expr(Env, Id = {id, As, _}) ->
    {QName, Type} = lookup_name(Env, As, Id),
    {typed, As, QName, Type};
infer_expr(Env, Id = {qid, As, _}) ->
    {QName, Type} = lookup_name(Env, As, Id),
    {typed, As, QName, Type};
infer_expr(Env, Id = {con, As, _}) ->
    {QName, Type} = lookup_name(Env, As, Id, [freshen]),
    {typed, As, QName, Type};
infer_expr(Env, {unit, As}) ->
    infer_expr(Env, {tuple, As, []});
infer_expr(Env, {tuple, As, Cpts}) ->
    NewCpts = [infer_expr(Env, C) || C <- Cpts],
    CptTypes = [T || {typed, _, _, T} <- NewCpts],
    {typed, As, {tuple, As, NewCpts}, {tuple_t, As, CptTypes}};
infer_expr(Env, {list, As, Elems}) ->
    ElemType = fresh_uvar(As),
    NewElems = [check_expr(Env, X, ElemType) || X <- Elems],
    {typed, As, {list, As, NewElems}, {app_t, As, {id, As, "list"}, [ElemType]}};
infer_expr(Env, {typed, As, Body, Type}) ->
    {typed, _, NewBody, NewType} = check_expr(Env, Body, Type),
    {typed, As, NewBody, NewType};
infer_expr(Env, {app, Ann, Fun, Args0}) ->
    %% TODO: fix parser to give proper annotation for normal applications!
    FunAnn     = aeso_syntax:get_ann(Fun),
    NamedArgs  = [ Arg || Arg = {named_arg, _, _, _} <- Args0 ],
    Args       = Args0 -- NamedArgs,
    case aeso_syntax:get_ann(format, Ann) of
        infix ->
            infer_op(Env, Ann, Fun, Args, fun infer_infix/1);
        prefix ->
            infer_op(Env, Ann, Fun, Args, fun infer_prefix/1);
        _ ->
            NamedArgsVar = fresh_uvar(FunAnn),
            NamedArgs1 = [ infer_named_arg(Env, NamedArgsVar, Arg) || Arg <- NamedArgs ],
            %% TODO: named args constraints
            NewFun={typed, _, _, FunType} = infer_expr(Env, Fun),
            NewArgs = [infer_expr(Env, A) || A <- Args],
            ArgTypes = [T || {typed, _, _, T} <- NewArgs],
            ResultType = fresh_uvar(FunAnn),
            unify(Env, FunType, {fun_t, [], NamedArgsVar, ArgTypes, ResultType}, {infer_app, Fun, Args, FunType, ArgTypes}),
            {typed, FunAnn, {app, Ann, NewFun, NamedArgs1 ++ NewArgs}, dereference(ResultType)}
    end;
infer_expr(Env, {'if', Attrs, Cond, Then, Else}) ->
    NewCond = check_expr(Env, Cond, {id, Attrs, "bool"}),
    NewThen = {typed, _, _, ThenType} = infer_expr(Env, Then),
    NewElse = {typed, _, _, ElseType} = infer_expr(Env, Else),
    unify(Env, ThenType, ElseType, {if_branches, Then, ThenType, Else, ElseType}),
    {typed, Attrs, {'if', Attrs, NewCond, NewThen, NewElse}, ThenType};
infer_expr(Env, {switch, Attrs, Expr, Cases}) ->
    NewExpr = {typed, _, _, ExprType} = infer_expr(Env, Expr),
    SwitchType = fresh_uvar(Attrs),
    NewCases = [infer_case(Env, As, Pattern, ExprType, Branch, SwitchType)
                || {'case', As, Pattern, Branch} <- Cases],
    {typed, Attrs, {switch, Attrs, NewExpr, NewCases}, SwitchType};
infer_expr(Env, {record, Attrs, Fields}) ->
    RecordType = fresh_uvar(Attrs),
    NewFields = [{field, A, FieldName, infer_expr(Env, Expr)}
                 || {field, A, FieldName, Expr} <- Fields],
    RecordType1 = unfold_types_in_type(Env, RecordType),
    constrain([ #record_create_constraint{
                    record_t = RecordType1,
                    fields   = [ FieldName || {field, _, [{proj, _, FieldName}], _} <- Fields ],
                    context  = Attrs } ] ++
              [begin
                [{proj, _, FieldName}] = LV,
                #field_constraint{
                    record_t = RecordType1,
                    field    = FieldName,
                    field_t  = T,
                    kind     = create,
                    context  = Fld}
               end || {Fld, {field, _, LV, {typed, _, _, T}}} <- lists:zip(Fields, NewFields)]),
    {typed, Attrs, {record, Attrs, NewFields}, RecordType};
infer_expr(Env, {record, Attrs, Record, Update}) ->
    NewRecord = {typed, _, _, RecordType} = infer_expr(Env, Record),
    NewUpdate = [ check_record_update(Env, RecordType, Fld) || Fld <- Update ],
    {typed, Attrs, {record, Attrs, NewRecord, NewUpdate}, RecordType};
infer_expr(Env, {proj, Attrs, Record, FieldName}) ->
    NewRecord = {typed, _, _, RecordType} = infer_expr(Env, Record),
    FieldType = fresh_uvar(Attrs),
    constrain([#field_constraint{
        record_t = unfold_types_in_type(Env, RecordType),
        field    = FieldName,
        field_t  = FieldType,
        kind     = project,
        context  = {proj, Attrs, Record, FieldName} }]),
    {typed, Attrs, {proj, Attrs, NewRecord, FieldName}, FieldType};
%% Maps
infer_expr(Env, {map_get, Attrs, Map, Key}) ->  %% map lookup
    KeyType = fresh_uvar(Attrs),
    ValType = fresh_uvar(Attrs),
    MapType = map_t(Attrs, KeyType, ValType),
    Map1 = check_expr(Env, Map, MapType),
    Key1 = check_expr(Env, Key, KeyType),
    {typed, Attrs, {map_get, Attrs, Map1, Key1}, ValType};
infer_expr(Env, {map_get, Attrs, Map, Key, Val}) ->  %% map lookup with default
    KeyType = fresh_uvar(Attrs),
    ValType = fresh_uvar(Attrs),
    MapType = map_t(Attrs, KeyType, ValType),
    Map1 = check_expr(Env, Map, MapType),
    Key1 = check_expr(Env, Key, KeyType),
    Val1 = check_expr(Env, Val, ValType),
    {typed, Attrs, {map_get, Attrs, Map1, Key1, Val1}, ValType};
infer_expr(Env, {map, Attrs, KVs}) ->   %% map construction
    KeyType = fresh_uvar(Attrs),
    ValType = fresh_uvar(Attrs),
    KVs1 = [ {check_expr(Env, K, KeyType), check_expr(Env, V, ValType)}
             || {K, V} <- KVs ],
    {typed, Attrs, {map, Attrs, KVs1}, map_t(Attrs, KeyType, ValType)};
infer_expr(Env, {map, Attrs, Map, Updates}) -> %% map update
    KeyType  = fresh_uvar(Attrs),
    ValType  = fresh_uvar(Attrs),
    MapType  = map_t(Attrs, KeyType, ValType),
    Map1     = check_expr(Env, Map, MapType),
    Updates1 = [ check_map_update(Env, Upd, KeyType, ValType) || Upd <- Updates ],
    {typed, Attrs, {map, Attrs, Map1, Updates1}, MapType};
infer_expr(Env, {block, Attrs, Stmts}) ->
    BlockType = fresh_uvar(Attrs),
    NewStmts = infer_block(Env, Attrs, Stmts, BlockType),
    {typed, Attrs, {block, Attrs, NewStmts}, BlockType};
infer_expr(Env, {lam, Attrs, Args, Body}) ->
    ArgTypes = [fresh_uvar(As) || {arg, As, _, _} <- Args],
    ArgPatterns = [{typed, As, Pat, T} || {arg, As, Pat, T} <- Args],
    ResultType = fresh_uvar(Attrs),
    {'case', _, {typed, _, {tuple, _, NewArgPatterns}, _}, NewBody} =
        infer_case(Env, Attrs, {tuple, Attrs, ArgPatterns}, {tuple_t, Attrs, ArgTypes}, Body, ResultType),
    NewArgs = [{arg, As, NewPat, NewT} || {typed, As, NewPat, NewT} <- NewArgPatterns],
    {typed, Attrs, {lam, Attrs, NewArgs, NewBody}, {fun_t, Attrs, [], ArgTypes, ResultType}}.

infer_named_arg(Env, NamedArgs, {named_arg, Ann, Id, E}) ->
    CheckedExpr = {typed, _, _, ArgType} = infer_expr(Env, E),
    add_named_argument_constraint(
        #named_argument_constraint{
            args = NamedArgs,
            name = Id,
            type = ArgType }),
    {named_arg, Ann, Id, CheckedExpr}.

check_map_update(Env, {field, Ann, [{map_get, Ann1, Key}], Val}, KeyType, ValType) ->
    Key1 = check_expr(Env, Key, KeyType),
    Val1 = check_expr(Env, Val, ValType),
    {field, Ann, [{map_get, Ann1, Key1}], Val1};
check_map_update(_Env, Upd={field, _Ann, [{map_get, _Ann1, _Key, _Def}], _Val}, _KeyType, _ValType) ->
    type_error({unnamed_map_update_with_default, Upd});
check_map_update(Env, {field, Ann, [{map_get, Ann1, Key}], Id, Val}, KeyType, ValType) ->
    FunType = {fun_t, Ann, [], [ValType], ValType},
    Key1    = check_expr(Env, Key, KeyType),
    Fun     = check_expr(Env, {lam, Ann1, [{arg, Ann1, Id, ValType}], Val}, FunType),
    {field_upd, Ann, [{map_get, Ann1, Key1}], Fun};
check_map_update(Env, {field, Ann, [{map_get, Ann1, Key, Def}], Id, Val}, KeyType, ValType) ->
    FunType = {fun_t, Ann, [], [ValType], ValType},
    Key1    = check_expr(Env, Key, KeyType),
    Def1    = check_expr(Env, Def, ValType),
    Fun     = check_expr(Env, {lam, Ann1, [{arg, Ann1, Id, ValType}], Val}, FunType),
    {field_upd, Ann, [{map_get, Ann1, Key1, Def1}], Fun};
check_map_update(_, {field, Ann, Flds, _}, _, _) ->
    error({nested_map_updates_not_implemented, Ann, Flds}).

check_record_update(Env, RecordType, Fld) ->
    [field, Ann, LV = [{proj, Ann1, FieldName}] | Val] = tuple_to_list(Fld),
    FldType = fresh_uvar(Ann),
    Fld1 = case Val of
            [Expr] ->
                {field, Ann, LV, check_expr(Env, Expr, FldType)};
            [Id, Expr] ->
                Fun     = {lam, Ann1, [{arg, Ann1, Id, FldType}], Expr},
                FunType = {fun_t, Ann1, [], [FldType], FldType},
                {field_upd, Ann, LV, check_expr(Env, Fun, FunType)}
        end,
    constrain([#field_constraint{
        record_t = unfold_types_in_type(Env, RecordType),
        field    = FieldName,
        field_t  = FldType,
        kind     = update,
        context  = Fld }]),
    Fld1.

infer_op(Env, As, Op, Args, InferOp) ->
    TypedArgs = [infer_expr(Env, A) || A <- Args],
    ArgTypes = [T || {typed, _, _, T} <- TypedArgs],
    Inferred = {fun_t, _, _, OperandTypes, ResultType} = InferOp(Op),
    unify(Env, ArgTypes, OperandTypes, {infer_app, Op, Args, Inferred, ArgTypes}),
    {typed, As, {app, As, Op, TypedArgs}, ResultType}.

infer_case(Env, Attrs, Pattern, ExprType, Branch, SwitchType) ->
    Vars = free_vars(Pattern),
    Names = [N || {id, _, N} <- Vars, N /= "_"],
    case Names -- lists:usort(Names) of
        [] -> ok;
        Nonlinear -> type_error({non_linear_pattern, Pattern, lists:usort(Nonlinear)})
    end,
    NewEnv = bind_vars([{Var, fresh_uvar(Ann)} || Var = {id, Ann, _} <- Vars], Env),
    NewPattern = {typed, _, _, PatType} = infer_expr(NewEnv, Pattern),
    NewBranch  = check_expr(NewEnv, Branch, SwitchType),
    unify(Env, PatType, ExprType, {case_pat, Pattern, PatType, ExprType}),
    {'case', Attrs, NewPattern, NewBranch}.

%% NewStmts = infer_block(Env, Attrs, Stmts, BlockType)
infer_block(_Env, Attrs, [], BlockType) ->
    error({impossible, empty_block, Attrs, BlockType});
infer_block(Env, Attrs, [Def={letfun, _, _, _, _, _}|Rest], BlockType) ->
    NewDef = infer_letfun(Env, Def),
    [NewDef|infer_block(Env, Attrs, Rest, BlockType)];
infer_block(Env, Attrs, [Def={letrec, _, _}|Rest], BlockType) ->
    NewDef = infer_letrec(Env, Def),
    [NewDef|infer_block(Env, Attrs, Rest, BlockType)];
infer_block(Env, _, [{letval, Attrs, Pattern, Type, E}|Rest], BlockType) ->
    NewE = {typed, _, _, PatType} = infer_expr(Env, {typed, Attrs, E, arg_type(Type)}),
    {'case', _, NewPattern, {typed, _, {block, _, NewRest}, _}} =
        infer_case(Env, Attrs, Pattern, PatType, {block, Attrs, Rest}, BlockType),
    [{letval, Attrs, NewPattern, Type, NewE}|NewRest];
infer_block(Env, _, [E], BlockType) ->
    [check_expr(Env, E, BlockType)];
infer_block(Env, Attrs, [E|Rest], BlockType) ->
    [infer_expr(Env, E)|infer_block(Env, Attrs, Rest, BlockType)].

infer_infix({BoolOp, As})
  when BoolOp =:= '&&'; BoolOp =:= '||' ->
    Bool = {id, As, "bool"},
    {fun_t, As, [], [Bool,Bool], Bool};
infer_infix({IntOp, As})
  when IntOp == '+';    IntOp == '-';   IntOp == '*';   IntOp == '/';
       IntOp == '^';    IntOp == 'mod' ->
    Int = {id, As, "int"},
    {fun_t, As, [], [Int, Int], Int};
infer_infix({RelOp, As})
  when RelOp == '=='; RelOp == '!=';
       RelOp == '<';  RelOp == '>';
       RelOp == '<='; RelOp == '=<'; RelOp == '>=' ->
    T = fresh_uvar(As),     %% allow any type here, check in ast_to_icode that we have comparison for it
    Bool = {id, As, "bool"},
    {fun_t, As, [], [T, T], Bool};
infer_infix({'::', As}) ->
    ElemType = fresh_uvar(As),
    ListType = {app_t, As, {id, As, "list"}, [ElemType]},
    {fun_t, As, [], [ElemType, ListType], ListType};
infer_infix({'++', As}) ->
    ElemType = fresh_uvar(As),
    ListType = {app_t, As, {id, As, "list"}, [ElemType]},
    {fun_t, As, [], [ListType, ListType], ListType}.

infer_prefix({'!',As}) ->
    Bool = {id, As, "bool"},
    {fun_t, As, [], [Bool], Bool};
infer_prefix({IntOp,As}) when IntOp =:= '-' ->
    Int = {id, As, "int"},
    {fun_t, As, [], [Int], Int}.

free_vars({int, _, _}) ->
    [];
free_vars({string, _, _}) ->
    [];
free_vars({bool, _, _}) ->
    [];
free_vars(Id={id, _, _}) ->
    [Id];
free_vars({con, _, _}) ->
    [];
free_vars({tuple, _, Cpts}) ->
    free_vars(Cpts);
free_vars({list, _, Elems}) ->
    free_vars(Elems);
free_vars({app, _, {'::', _}, Args}) ->
    free_vars(Args);
free_vars({app, _, {con, _, _}, Args}) ->
    free_vars(Args);
free_vars({record, _, Fields}) ->
    free_vars([E || {field, _, _, E} <- Fields]);
free_vars({typed, _, A, _}) ->
    free_vars(A);
free_vars(L) when is_list(L) ->
    [V || Elem <- L,
          V <- free_vars(Elem)].

%% Clean up all the ets tables (in case of an exception)

ets_tables() ->
    [options, type_vars, type_defs, record_fields, named_argument_constraints,
     field_constraints, freshen_tvars, type_errors].

clean_up_ets() ->
    [ catch ets_delete(Tab) || Tab <- ets_tables() ],
    ok.

%% Named interface to ETS tables implemented without names.
%% The interface functions behave as the standard ETS interface.

ets_init() ->
    put(aeso_ast_infer_types, #{}).

ets_tabid(Name) ->
    #{Name := TabId} = get(aeso_ast_infer_types),
    TabId.

ets_new(Name, Opts) ->
    %% Ensure the table is NOT named!
    TabId = ets:new(Name, Opts -- [named_table]),
    Tabs = get(aeso_ast_infer_types),
    put(aeso_ast_infer_types, Tabs#{Name => TabId}),
    Name.

ets_delete(Name) ->
    Tabs = get(aeso_ast_infer_types),
    #{Name := TabId} = Tabs,
    put(aeso_ast_infer_types, maps:remove(Name, Tabs)),
    ets:delete(TabId).

ets_insert(Name, Object) ->
    TabId = ets_tabid(Name),
    ets:insert(TabId, Object).

ets_lookup(Name, Key) ->
    TabId = ets_tabid(Name),
    ets:lookup(TabId, Key).

ets_tab2list(Name) ->
    TabId = ets_tabid(Name),
    ets:tab2list(TabId).

%% Options

create_options(Options) ->
    ets_new(options, [set]),
    Tup = fun(Opt) when is_atom(Opt) -> {Opt, true};
             (Opt) when is_tuple(Opt) -> Opt end,
    ets_insert(options, lists:map(Tup, Options)).

get_option(Key, Default) ->
    case ets_lookup(options, Key) of
        [{Key, Val}] -> Val;
        _            -> Default
    end.

when_option(Opt, Do) ->
    get_option(Opt, false) andalso Do().

%% Record types

%% create_type_defs(Defs) ->
%%     %% A map from type names to definitions
%%     ets_new(type_defs, [set]),
%%     %% A relation from field names to types
%%     ets_new(record_fields, [bag]),
%%     [ case Def of
%%         {type_def, _Attrs, Id, Args, Typedef} ->
%%             insert_typedef(Id, Args, Typedef);
%%         {contract, _Attrs, Id, Contents} ->
%%             insert_contract(Id, Contents);
%%         _ -> ok
%%       end || Def <- Defs],
%%     ok.

%% destroy_type_defs() ->
%%     ets_delete(type_defs),
%%     ets_delete(record_fields).

%% Key used in type_defs ets table.
%% -spec type_key(type_id()) -> [string()].
%% type_key({Tag, _, Name})  when Tag =:= id;  Tag =:= con  -> [Name];
%% type_key({Tag, _, QName}) when Tag =:= qid; Tag =:= qcon -> QName.

%% Contract entrypoints take two named arguments (gas : int = Call.gas_left(), value : int = 0).
%% contract_call_type({fun_t, Ann, [], Args, Ret}) ->
%%     Id    = fun(X) -> {id, Ann, X} end,
%%     Int   = Id("int"),
%%     Typed = fun(E, T) -> {typed, Ann, E, T} end,
%%     Named = fun(Name, Default) -> {named_arg_t, Ann, Id(Name), Int, Default} end,
%%     {fun_t, Ann, [Named("gas",   Typed({app, Ann, Typed({qid, Ann, ["Call", "gas_left"]},
%%                                                         {fun_t, Ann, [], [], Int}),
%%                                         []}, Int)),
%%                   Named("value", Typed({int, Ann, 0}, Int))], Args, Ret}.

%% insert_contract(Id, Contents) ->
%%     Key = type_key(Id),
%%     Sys    = [{origin, system}],
%%     Fields = [ {field_t, Ann, Entrypoint, contract_call_type(Type)}
%%                 || {fun_decl, Ann, Entrypoint, Type} <- Contents ] ++
%%               %% Predefined fields
%%              [ {field_t, Sys, {id, Sys, "address"}, {id, Sys, "address"}} ],
%%     ets_insert(type_defs, {Key, [], {contract_t, Fields}}),
%%     %% TODO: types defined in other contracts
%%     [insert_record_field(Entrypoint, #field_info{ kind     = contract,
%%                                                   field_t  = Type,
%%                                                   record_t = Id })
%%      || {field_t, _, {id, _, Entrypoint}, Type} <- Fields ].

%% -spec insert_typedef(type_id(), [aeso_syntax:tvar()], aeso_syntax:typedef()) -> ok.
%% insert_typedef(Id, Args, Typedef) ->
%%     Attrs = aeso_syntax:get_ann(Id),
%%     Key   = type_key(Id),
%%     ets_insert(type_defs, {Key, Args, Typedef}),
%%     case Typedef of
%%         {record_t, Fields} ->
%%             [insert_record_field(FieldName, #field_info{ kind     = record,
%%                                                          field_t  = FieldType,
%%                                                          record_t = {app_t, Attrs, Id, Args} })
%%              || {field_t, _, {id, _, FieldName}, FieldType} <- Fields],
%%             ok;
%%         {variant_t, _} -> ok;
%%         {alias_t, _} -> ok
%%     end.

%% -spec lookup_type(type_id()) -> false | {[aeso_syntax:tvar()], aeso_syntax:typedef()}.
%% lookup_type(Id) ->
%%     case ets_lookup(type_defs, type_key(Id)) of
%%         []                        -> false;
%%         [{_Key, Params, Typedef}] ->
%%             {Params, unfold_types_in_type(push_anns(Id, Typedef))}
%%     end.

push_anns(T1, {Ann, {Args, {alias_t, Id}}}) ->
    As1 = aeso_syntax:get_ann(T1),
    As2 = aeso_syntax:get_ann(Id),
    As = umerge(lists:sort(As2), lists:sort(As1)),
    {Ann, {Args, {alias_t, aeso_syntax:set_ann(As, Id)}}};
push_anns(_, T) -> T.

umerge([], Ls2) -> Ls2;
umerge(Ls1, []) -> Ls1;
umerge([E = {K, _V1} | Ls1], [{K, _V2} | Ls2]) ->
    [E | umerge(Ls1, Ls2)];
umerge([E = {K1, _V1} | Ls1], Ls2 = [{K2, _V2} | _]) when K1 < K2 ->
    [E | umerge(Ls1, Ls2)];
umerge(Ls1 = [{K1, _V1} | _], [E = {K2, _V2} | Ls2]) when K2 < K1 ->
    [E | umerge(Ls1, Ls2)].


%% -spec insert_record_field(string(), field_info()) -> true.
%% insert_record_field(FieldName, FieldInfo) ->
%%     ets_insert(record_fields, {FieldName, FieldInfo}).

%% -- Constraints --

create_constraints() ->
    create_named_argument_constraints(),
    create_field_constraints().

solve_constraints(Env) ->
    solve_named_argument_constraints(Env),
    solve_field_constraints(Env).

destroy_and_report_unsolved_constraints(Env) ->
    destroy_and_report_unsolved_field_constraints(Env),
    destroy_and_report_unsolved_named_argument_constraints(Env).

%% -- Named argument constraints --

create_named_argument_constraints() ->
    ets_new(named_argument_constraints, [bag]).

destroy_named_argument_constraints() ->
    ets_delete(named_argument_constraints).

get_named_argument_constraints() ->
    ets_tab2list(named_argument_constraints).

-spec add_named_argument_constraint(named_argument_constraint()) -> ok.
add_named_argument_constraint(Constraint) ->
    ets_insert(named_argument_constraints, Constraint),
    ok.

solve_named_argument_constraints(Env) ->
    Unsolved = solve_named_argument_constraints(Env, get_named_argument_constraints()),
    Unsolved == [].

-spec solve_named_argument_constraints(env(), [named_argument_constraint()]) -> [named_argument_constraint()].
solve_named_argument_constraints(Env, Constraints0) ->
    [ C || C <- dereference_deep(Constraints0),
           unsolved == check_named_argument_constraint(Env, C) ].

%% If false, a type error have been emitted, so it's safe to drop the constraint.
-spec check_named_argument_constraint(env(), named_argument_constraint()) -> true | false | unsolved.
check_named_argument_constraint(_Env, #named_argument_constraint{ args = {uvar, _, _} }) ->
    unsolved;
check_named_argument_constraint(Env,
        C = #named_argument_constraint{ args = Args,
                                        name = Id = {id, _, Name},
                                        type = Type }) ->
    case [ T || {named_arg_t, _, {id, _, Name1}, T, _} <- Args, Name1 == Name ] of
        []  ->
            type_error({bad_named_argument, Args, Id}),
            false;
        [T] -> unify(Env, T, Type, {check_named_arg_constraint, C}), true
    end.

destroy_and_report_unsolved_named_argument_constraints(Env) ->
    Unsolved = solve_named_argument_constraints(Env, get_named_argument_constraints()),
    [ type_error({unsolved_named_argument_constraint, C}) || C <- Unsolved ],
    destroy_named_argument_constraints(),
    ok.

%% -- Field constraints --

create_field_constraints() ->
    %% A relation from uvars to constraints
    ets_new(field_constraints, [bag]).

destroy_field_constraints() ->
    ets_delete(field_constraints).

-spec constrain([field_constraint()]) -> true.
constrain(FieldConstraints) ->
    ets_insert(field_constraints, FieldConstraints).

-spec get_field_constraints() -> [field_constraint()].
get_field_constraints() ->
    ets_tab2list(field_constraints).

solve_field_constraints(Env) ->
    FieldCs =
        lists:filter(fun(#field_constraint{}) -> true; (_) -> false end,
                        get_field_constraints()),
    solve_field_constraints(Env, FieldCs).

check_record_create_constraints(_, []) -> ok;
check_record_create_constraints(Env, [C | Cs]) ->
    #record_create_constraint{
        record_t = Type,
        fields   = Fields,
        context  = When } = C,
    Type1 = unfold_types_in_type(Env, instantiate(Type)),
    try lookup_type(Env, record_type_name(Type1)) of
        {_QId, {_Ann, {_Args, {record_t, RecFields}}}} ->
            ActualNames = [ Fld || {field_t, _, {id, _, Fld}, _} <- RecFields ],
            GivenNames  = [ Fld || {id, _, Fld} <- Fields ],
            case ActualNames -- GivenNames of   %% We know already that we don't have too many fields
                []      -> ok;
                Missing -> type_error({missing_fields, When, Type1, Missing})
            end;
        _ -> %% We can get here if there are other type errors.
            ok
    catch _:_ ->    %% Might be unsolved, we get a different error in that case
        ok
    end,
    check_record_create_constraints(Env, Cs).

-spec solve_field_constraints(env(), [field_constraint()]) -> ok.
solve_field_constraints(Env, Constraints) ->
    %% First look for record fields that appear in only one type definition
    IsAmbiguous = fun(#field_constraint{
                        record_t = RecordType,
                        field    = Field={id, _Attrs, FieldName},
                        field_t  = FieldType,
                        kind     = Kind,
                        context  = When }) ->
        case lookup_record_field(Env, FieldName, Kind) of
            [] ->
                type_error({undefined_field, Field}),
                false;
            [{FieldName, #field_info{field_t = FldType, record_t = RecType}}] ->
                create_freshen_tvars(),
                FreshFldType = freshen(FldType),
                FreshRecType = freshen(RecType),
                destroy_freshen_tvars(),
                unify(Env, FreshFldType, FieldType, {field_constraint, FreshFldType, FieldType, When}),
                unify(Env, FreshRecType, RecordType, {record_constraint, FreshRecType, RecordType, When}),
                false;
            _ ->
                %% ambiguity--need cleverer strategy
                true
         end end,
    AmbiguousConstraints = lists:filter(IsAmbiguous, Constraints),
    solve_ambiguous_field_constraints(Env, AmbiguousConstraints).

-spec solve_ambiguous_field_constraints(env(), [field_constraint()]) -> ok.
solve_ambiguous_field_constraints(Env, Constraints) ->
    Unknown = solve_known_record_types(Env, Constraints),
    if Unknown == [] -> ok;
       length(Unknown) < length(Constraints) ->
            %% progress! Keep trying.
            solve_ambiguous_field_constraints(Env, Unknown);
       true ->
            case solve_unknown_record_types(Env, Unknown) of
                true -> %% Progress!
                    solve_ambiguous_field_constraints(Env, Unknown);
                _ -> ok %% No progress. Report errors later.
            end
    end.

-spec solve_unknown_record_types(env(), [field_constraint()]) -> true | [tuple()].
solve_unknown_record_types(Env, Unknown) ->
    UVars = lists:usort([UVar || #field_constraint{record_t = UVar = {uvar, _, _}} <- Unknown]),
    Solutions = [solve_for_uvar(Env, UVar, [{Kind, When, Field}
                                            || #field_constraint{record_t = U, field = Field, kind = Kind, context = When} <- Unknown,
                                               U == UVar])
                 || UVar <- UVars],
    case lists:member(true, Solutions) of
        true  -> true;
        false -> Solutions
    end.

-spec solve_known_record_types(env(), [field_constraint()]) -> [field_constraint()].
solve_known_record_types(Env, Constraints) ->
    DerefConstraints =
        [ C#field_constraint{record_t = dereference(RecordType)}
         || C = #field_constraint{record_t = RecordType} <- Constraints ],
    SolvedConstraints =
        [begin
            #field_constraint{record_t = RecType,
                              field    = FieldName,
                              field_t  = FieldType,
                              context  = When} = C,
            RecId = record_type_name(RecType),
            Attrs = aeso_syntax:get_ann(RecId),
            case lookup_type(Env, RecId) of
                {_, {_Ann, {Formals, {What, Fields}}}} when What =:= record_t; What =:= contract_t ->
                     FieldTypes = [{Name, Type} || {field_t, _, {id, _, Name}, Type} <- Fields],
                     {id, _, FieldString} = FieldName,
                     case proplists:get_value(FieldString, FieldTypes) of
                         undefined ->
                             type_error({missing_field, FieldName, RecId}),
                             not_solved;
                         FldType ->
                             create_freshen_tvars(),
                             FreshFldType = freshen(FldType),
                             FreshRecType = freshen(app_t(Attrs, RecId, Formals)),
                             destroy_freshen_tvars(),
                             unify(Env, FreshFldType, FieldType, {field_constraint, FreshFldType, FieldType, When}),
                             unify(Env, FreshRecType, RecType, {record_constraint, FreshRecType, RecType, When}),
                             C
                     end;
                _ ->
                    type_error({not_a_record_type, RecId, When}),
                    not_solved
             end
         end
         || C <- DerefConstraints,
            case C#field_constraint.record_t of
                {uvar, _, _} -> false;
                _          -> true
            end],
    DerefConstraints--SolvedConstraints.

destroy_and_report_unsolved_field_constraints(Env) ->
    {FieldCs, CreateCs} =
        lists:partition(fun(#field_constraint{}) -> true; (_) -> false end,
                        get_field_constraints()),
    Unknown  = solve_known_record_types(Env, FieldCs),
    if Unknown == [] -> ok;
       true ->
            case solve_unknown_record_types(Env, Unknown) of
                true   -> ok;
                Errors -> [ type_error(Err) || Err <- Errors ]
            end
    end,
    check_record_create_constraints(Env, CreateCs),
    destroy_field_constraints(),
    ok.

record_type_name({app_t, _Attrs, RecId, _Args}) when ?is_type_id(RecId) ->
    RecId;
record_type_name(RecId) when ?is_type_id(RecId) ->
    RecId;
record_type_name(_Other) ->
    %% io:format("~p is not a record type\n", [Other]),
    {id, [{origin, system}], "not_a_record_type"}.

solve_for_uvar(Env, UVar = {uvar, Attrs, _}, Fields0) ->
    Fields = [{Kind, Fld} || {Kind, _, Fld} <- Fields0],
    [{_, When, _} | _] = Fields0,    %% Get the location from the first field
    %% If we have 'create' constraints they must be complete.
    Covering = lists:usort([ Name || {create, {id, _, Name}} <- Fields ]),
    %% Does this set of fields uniquely identify a record type?
    FieldNames = [ Name || {_Kind, {id, _, Name}} <- Fields ],
    UniqueFields = lists:usort(FieldNames),
    Candidates = [RecType || #field_info{record_t = RecType} <- lookup_record_field(Env, hd(FieldNames))],
    TypesAndFields = [case lookup_type(Env, record_type_name(RecType)) of
                        {_, {_, {_, {record_t, RecFields}}}} ->
                            {RecType, [Field || {field_t, _, {id, _, Field}, _} <- RecFields]};
                        {_, {_, {_, {contract_t, ConFields}}}} ->
                            %% TODO: is this right?
                            {RecType, [Field || {field_t, _, {id, _, Field}, _} <- ConFields]};
                        false -> %% impossible?
                            error({no_definition_for, record_type_name(RecType), in, Env})
                      end
                      || RecType <- Candidates],
    PartialSolutions =
        lists:sort([{RecType, if Covering == [] -> []; true -> RecFields -- Covering end}
                    || {RecType, RecFields} <- TypesAndFields,
                       UniqueFields -- RecFields == []]),
    Solutions = [RecName || {RecName, []} <- PartialSolutions],
    case {Solutions, PartialSolutions} of
        {[], []} ->
            {no_records_with_all_fields, Fields};
        {[], _} ->
            case PartialSolutions of
                [{RecType, Missing} | _] -> %% TODO: better error if ambiguous
                    {missing_fields, When, RecType, Missing}
            end;
        {[RecType], _} ->
            RecName = record_type_name(RecType),
            {_, {_, {Formals, {_RecOrCon, _}}}} = lookup_type(Env, RecName),
            create_freshen_tvars(),
            FreshRecType = freshen(app_t(Attrs, RecName, Formals)),
            destroy_freshen_tvars(),
            unify(Env, UVar, FreshRecType, {solve_rec_type, UVar, Fields}),
            true;
        {StillPossible, _} ->
            {ambiguous_record, Fields, StillPossible}
    end.

%% During type inference, record types are represented by their
%% names. But, before we pass the typed program to the code generator,
%% we replace record types annotating expressions with their
%% definition. This enables the code generator to see the fields.
unfold_record_types(Env, T) ->
    unfold_types(Env, T, [unfold_record_types]).

unfold_types(Env, {typed, Attr, E, Type}, Options) ->
    {typed, Attr, unfold_types(Env, E, Options), unfold_types_in_type(Env, Type, Options)};
unfold_types(Env, {arg, Attr, Id, Type}, Options) ->
    {arg, Attr, Id, unfold_types_in_type(Env, Type, Options)};
unfold_types(Env, {type_sig, Ann, NamedArgs, Args, Ret}, Options) ->
    {type_sig, Ann,
               unfold_types_in_type(Env, NamedArgs, Options),
               unfold_types_in_type(Env, Args, Options),
               unfold_types_in_type(Env, Ret, Options)};
unfold_types(Env, {type_def, Ann, Name, Args, Def}, Options) ->
    {type_def, Ann, Name, Args, unfold_types_in_type(Env, Def, Options)};
unfold_types(Env, {fun_decl, Ann, Name, Type}, Options) ->
    {fun_decl, Ann, Name, unfold_types(Env, Type, Options)};
unfold_types(Env, {letfun, Ann, Name, Args, Type, Body}, Options) ->
    {letfun, Ann, Name, unfold_types(Env, Args, Options), unfold_types_in_type(Env, Type, Options), unfold_types(Env, Body, Options)};
unfold_types(Env, T, Options) when is_tuple(T) ->
    list_to_tuple(unfold_types(Env, tuple_to_list(T), Options));
unfold_types(Env, [H|T], Options) ->
    [unfold_types(Env, H, Options)|unfold_types(Env, T, Options)];
unfold_types(_Env, X, _Options) ->
    X.

unfold_types_in_type(Env, T) ->
    unfold_types_in_type(Env, T, []).

unfold_types_in_type(Env, {app_t, Ann, Id, Args}, Options) when ?is_type_id(Id) ->
    UnfoldRecords = proplists:get_value(unfold_record_types, Options, false),
    case lookup_type(Env, Id) of
        {_, {_, {Formals, {record_t, Fields}}}} when UnfoldRecords, length(Formals) == length(Args) ->
            {record_t,
             unfold_types_in_type(Env,
               subst_tvars(lists:zip(Formals, Args), Fields), Options)};
        {_, {_, {Formals, {alias_t, Type}}}} when length(Formals) == length(Args) ->
            unfold_types_in_type(Env, subst_tvars(lists:zip(Formals, Args), Type), Options);
        _ ->
            %% Not a record type, or ill-formed record type.
            {app_t, Ann, Id, unfold_types_in_type(Env, Args, Options)}
    end;
unfold_types_in_type(Env, Id, Options) when ?is_type_id(Id) ->
    %% Like the case above, but for types without parameters.
    UnfoldRecords = proplists:get_value(unfold_record_types, Options, false),
    case lookup_type(Env, Id) of
        {_, {_, {[], {record_t, Fields}}}} when UnfoldRecords ->
            {record_t, unfold_types_in_type(Env, Fields, Options)};
        {_, {_, {[], {alias_t, Type1}}}} ->
            unfold_types_in_type(Env, Type1, Options);
        _ ->
            %% Not a record type, or ill-formed record type
            Id
    end;
unfold_types_in_type(Env, {field_t, Attr, Name, Type}, Options) ->
    {field_t, Attr, Name, unfold_types_in_type(Env, Type, Options)};
unfold_types_in_type(Env, T, Options) when is_tuple(T) ->
    list_to_tuple(unfold_types_in_type(Env, tuple_to_list(T), Options));
unfold_types_in_type(Env, [H|T], Options) ->
    [unfold_types_in_type(Env, H, Options)|unfold_types_in_type(Env, T, Options)];
unfold_types_in_type(_Env, X, _Options) ->
    X.


subst_tvars(Env, Type) ->
    subst_tvars1([{V, T} || {{tvar, _, V}, T} <- Env], Type).

subst_tvars1(Env, T={tvar, _, Name}) ->
    proplists:get_value(Name, Env, T);
subst_tvars1(Env, [H|T]) ->
    [subst_tvars1(Env, H)|subst_tvars1(Env, T)];
subst_tvars1(Env, Type) when is_tuple(Type) ->
    list_to_tuple(subst_tvars1(Env, tuple_to_list(Type)));
subst_tvars1(_Env, X) ->
    X.

%% Unification

unify(_, {id, _, "_"}, _, _When) -> true;
unify(_, _, {id, _, "_"}, _When) -> true;
unify(Env, A, B, When) ->
    A1 = dereference(unfold_types_in_type(Env, A)),
    B1 = dereference(unfold_types_in_type(Env, B)),
    unify1(Env, A1, B1, When).

unify1(_Env, {uvar, _, R}, {uvar, _, R}, _When) ->
    true;
unify1(_Env, {uvar, A, R}, T, When) ->
    case occurs_check(R, T) of
        true ->
            cannot_unify({uvar, A, R}, T, When),
            false;
        false ->
            ets_insert(type_vars, {R, T}),
            true
    end;
unify1(Env, T, {uvar, A, R}, When) ->
    unify1(Env, {uvar, A, R}, T, When);
unify1(_Env, {tvar, _, X}, {tvar, _, X}, _When) -> true; %% Rigid type variables
unify1(Env, [A|B], [C|D], When) ->
    unify(Env, A, C, When) andalso unify(Env, B, D, When);
unify1(_Env, X, X, _When) ->
    true;
unify1(_Env, {id, _, Name}, {id, _, Name}, _When) ->
    true;
unify1(_Env, {con, _, Name}, {con, _, Name}, _When) ->
    true;
unify1(_Env, {qid, _, Name}, {qid, _, Name}, _When) ->
    true;
unify1(_Env, {qcon, _, Name}, {qcon, _, Name}, _When) ->
    true;
unify1(Env, {fun_t, _, Named1, Args1, Result1}, {fun_t, _, Named2, Args2, Result2}, When) ->
    unify(Env, Named1, Named2, When) andalso
    unify(Env, Args1, Args2, When) andalso unify(Env, Result1, Result2, When);
unify1(Env, {app_t, _, {id, _, F}, Args1}, {app_t, _, {id, _, F}, Args2}, When)
  when length(Args1) == length(Args2) ->
    unify(Env, Args1, Args2, When);
unify1(Env, {tuple_t, _, As}, {tuple_t, _, Bs}, When)
  when length(As) == length(Bs) ->
    unify(Env, As, Bs, When);
%% The grammar is a bit inconsistent about whether types without
%% arguments are represented as applications to an empty list of
%% parameters or not. We therefore allow them to unify.
unify1(Env, {app_t, _, T, []}, B, When) ->
    unify(Env, T, B, When);
unify1(Env, A, {app_t, _, T, []}, When) ->
    unify(Env, A, T, When);
unify1(_Env, A, B, When) ->
    Ok =
        case get_option(permissive_address_literals, false) of
            true ->
                Kind = fun({qcon, _, _})       -> con;
                          ({con, _, _})        -> con;
                          ({id, _, "address"}) -> addr;
                          (_)                  -> other end,
                %% If permissive_address_literals we allow unifying contract types and address
                [addr, con] == lists:usort([Kind(A), Kind(B)]);
            false -> false
        end,
    [ cannot_unify(A, B, When) || not Ok ],
    Ok.

dereference(T = {uvar, _, R}) ->
    case ets_lookup(type_vars, R) of
        [] ->
            T;
        [{R, Type}] ->
            dereference(Type)
    end;
dereference(T) ->
    T.

dereference_deep(Type) ->
    case dereference(Type) of
        Tup when is_tuple(Tup) ->
            list_to_tuple(dereference_deep(tuple_to_list(Tup)));
        [H | T] -> [dereference_deep(H) | dereference_deep(T)];
        T -> T
    end.

occurs_check(R, T) ->
    occurs_check1(R, dereference(T)).

occurs_check1(R, {uvar, _, R1}) -> R == R1;
occurs_check1(_, {id, _, _}) -> false;
occurs_check1(_, {con, _, _}) -> false;
occurs_check1(_, {qid, _, _}) -> false;
occurs_check1(_, {qcon, _, _}) -> false;
occurs_check1(_, {tvar, _, _}) -> false;
occurs_check1(R, {fun_t, _, Named, Args, Res}) ->
    occurs_check(R, [Res, Named | Args]);
occurs_check1(R, {app_t, _, T, Ts}) ->
    occurs_check(R, [T | Ts]);
occurs_check1(R, {tuple_t, _, Ts}) ->
    occurs_check(R, Ts);
occurs_check1(R, {named_arg_t, _, _, T, _}) ->
    occurs_check(R, T);
occurs_check1(R, [H | T]) ->
    occurs_check(R, H) orelse occurs_check(R, T);
occurs_check1(_, []) -> false.

fresh_uvar(Attrs) ->
    {uvar, Attrs, make_ref()}.

create_freshen_tvars() ->
    ets_new(freshen_tvars, [set]).

destroy_freshen_tvars() ->
    ets_delete(freshen_tvars).

freshen_type(Type) ->
    create_freshen_tvars(),
    Type1 = freshen(Type),
    destroy_freshen_tvars(),
    Type1.

freshen({tvar, As, Name}) ->
    NewT = case ets_lookup(freshen_tvars, Name) of
               [] ->
                   fresh_uvar(As);
               [{Name, T}] ->
                   T
           end,
    ets_insert(freshen_tvars, {Name, NewT}),
    NewT;
freshen(T) when is_tuple(T) ->
    list_to_tuple(freshen(tuple_to_list(T)));
freshen([A|B]) ->
    [freshen(A)|freshen(B)];
freshen(X) ->
    X.

%% Dereferences all uvars and replaces the uninstantiated ones with a
%% succession of tvars.
instantiate(E) ->
    instantiate1(dereference(E)).

instantiate1({uvar, Attr, R}) ->
    Next = proplists:get_value(next, ets_lookup(type_vars, next), 1),
    TVar = {tvar, Attr, "'" ++ integer_to_list(Next)},
    ets_insert(type_vars, [{next, Next + 1}, {R, TVar}]),
    TVar;
instantiate1({fun_t, Ann, Named, Args, Ret}) ->
    case dereference(Named) of
        {uvar, _, R} ->
            %% Uninstantiated named args map to the empty list
            NoNames = [],
            ets_insert(type_vars, [{R, NoNames}]),
            {fun_t, Ann, NoNames, instantiate(Args), instantiate(Ret)};
        Named1 ->
            {fun_t, Ann, instantiate1(Named1), instantiate(Args), instantiate(Ret)}
    end;
instantiate1(T) when is_tuple(T) ->
    list_to_tuple(instantiate1(tuple_to_list(T)));
instantiate1([A|B]) ->
    [instantiate(A)|instantiate(B)];
instantiate1(X) ->
    X.

%% Save unification failures for error messages.

cannot_unify(A, B, When) ->
    type_error({cannot_unify, A, B, When}).

type_error(Err) ->
    ets_insert(type_errors, Err).

create_type_errors() ->
    ets_new(type_errors, [bag]).

destroy_and_report_type_errors() ->
    Errors   = ets_tab2list(type_errors),
    %% io:format("Type errors now: ~p\n", [Errors]),
    PPErrors = [ pp_error(Err) || Err <- Errors ],
    ets_delete(type_errors),
    Errors /= [] andalso
        error({type_errors, [lists:flatten(Err) || Err <- PPErrors]}).

pp_error({cannot_unify, A, B, When}) ->
    io_lib:format("Cannot unify ~s\n"
                  "         and ~s\n"
                  "~s", [pp(instantiate(A)), pp(instantiate(B)), pp_when(When)]);
pp_error({unbound_variable, Id}) ->
    io_lib:format("Unbound variable ~s at ~s\n", [pp(Id), pp_loc(Id)]);
pp_error({undefined_field, Id}) ->
    io_lib:format("Unbound field ~s at ~s\n", [pp(Id), pp_loc(Id)]);
pp_error({not_a_record_type, Type, Why}) ->
    io_lib:format("~s\n~s\n", [pp_type("Not a record type: ", Type), pp_why_record(Why)]);
pp_error({non_linear_pattern, Pattern, Nonlinear}) ->
    Plural = [ $s || length(Nonlinear) > 1 ],
    io_lib:format("Repeated name~s ~s in pattern\n~s (at ~s)\n",
                  [Plural, string:join(Nonlinear, ", "), pp_expr("  ", Pattern), pp_loc(Pattern)]);
pp_error({ambiguous_record, Fields = [{_, First} | _], Candidates}) ->
    S = [ "s" || length(Fields) > 1 ],
    io_lib:format("Ambiguous record type with field~s ~s (at ~s) could be one of\n~s",
                  [S, string:join([ pp(F) || {_, F} <- Fields ], ", "),
                   pp_loc(First),
                   [ ["  - ", pp(C), " (at ", pp_loc(C), ")\n"] || C <- Candidates ]]);
pp_error({missing_field, Field, Rec}) ->
    io_lib:format("Record type ~s does not have field ~s (at ~s)\n", [pp(Rec), pp(Field), pp_loc(Field)]);
pp_error({missing_fields, Ann, RecType, Fields}) ->
    Many = length(Fields) > 1,
    S    = [ "s" || Many ],
    Are  = if Many -> "are"; true -> "is" end,
    io_lib:format("The field~s ~s ~s missing when constructing an element of type ~s (at ~s)\n",
                  [S, string:join(Fields, ", "), Are, pp(RecType), pp_loc(Ann)]);
pp_error({no_records_with_all_fields, Fields = [{_, First} | _]}) ->
    S = [ "s" || length(Fields) > 1 ],
    io_lib:format("No record type with field~s ~s (at ~s)\n",
                  [S, string:join([ pp(F) || {_, F} <- Fields ], ", "),
                   pp_loc(First)]);
pp_error({recursive_types_not_implemented, Types}) ->
    S = if length(Types) > 1 -> "s are mutually";
           true              -> " is" end,
    io_lib:format("The following type~s recursive, which is not yet supported:\n~s",
                    [S, [io_lib:format("  - ~s (at ~s)\n", [pp(T), pp_loc(T)]) || T <- Types]]);
pp_error({event_0_to_3_indexed_values, Constr}) ->
    io_lib:format("The event constructor ~s has too many indexed values (max 3)\n", [Constr]);
pp_error({event_0_to_1_string_values, Constr}) ->
    io_lib:format("The event constructor ~s has too many string values (max 1)\n", [Constr]);
pp_error({repeated_constructor, Cs}) ->
    io_lib:format("Variant types must have distinct constructor names\n~s",
                  [[ io_lib:format("~s  (at ~s)\n", [pp_typed("  - ", C, T), pp_loc(C)]) || {C, T} <- Cs ]]);
pp_error({bad_named_argument, [], Name}) ->
    io_lib:format("Named argument ~s (at ~s) supplied to function expecting no named arguments.\n",
                  [pp(Name), pp_loc(Name)]);
pp_error({bad_named_argument, Args, Name}) ->
    io_lib:format("Named argument ~s (at ~s) is not one of the expected named arguments\n~s",
                  [pp(Name), pp_loc(Name),
                   [ io_lib:format("~s\n", [pp_typed("  - ", Arg, Type)])
                     || {named_arg_t, _, Arg, Type, _} <- Args ]]);
pp_error({unsolved_named_argument_constraint, #named_argument_constraint{name = Name, type = Type}}) ->
    io_lib:format("Named argument ~s (at ~s) supplied to function with unknown named arguments.\n",
                  [pp_typed("", Name, Type), pp_loc(Name)]);
pp_error({reserved_entrypoint, Name, Def}) ->
    io_lib:format("The name '~s' is reserved and cannot be used for a\ntop-level contract function (at ~s).\n",
                  [Name, pp_loc(Def)]);
pp_error({duplicate_definition, Name, Locs}) ->
    io_lib:format("Duplicate definitions of ~s at\n~s",
                  [Name, [ ["  - ", pp_loc(L), "\n"] || L <- Locs ]]);
pp_error({duplicate_scope, Kind, Name, OtherKind, L}) ->
    io_lib:format("The ~p ~s (at ~s) has the same name as a ~p at ~s\n",
                  [Kind, pp(Name), pp_loc(Name), OtherKind, pp_loc(L)]);
pp_error(Err) ->
    io_lib:format("Unknown error: ~p\n", [Err]).

pp_when({todo, What}) -> io_lib:format("[TODO] ~p\n", [What]);
pp_when({check_typesig, Name, Inferred, Given}) ->
    io_lib:format("when checking the definition of ~s\n"
                  "  inferred type: ~s\n"
                  "  given type:    ~s\n",
        [Name, pp(instantiate(Inferred)), pp(instantiate(Given))]);
pp_when({infer_app, Fun, Args, Inferred0, ArgTypes0}) ->
    Inferred = instantiate(Inferred0),
    ArgTypes = instantiate(ArgTypes0),
    io_lib:format("when checking the application at ~s of\n"
                  "~s\n"
                  "to arguments\n~s",
                  [pp_loc(Fun),
                   pp_typed("  ", Fun, Inferred),
                   [ [pp_typed("  ", Arg, ArgT), "\n"]
                      || {Arg, ArgT} <- lists:zip(Args, ArgTypes) ] ]);
pp_when({field_constraint, FieldType0, InferredType0, Fld}) ->
    FieldType    = instantiate(FieldType0),
    InferredType = instantiate(InferredType0),
    case Fld of
        {field, _Ann, LV, Id, E} ->
            io_lib:format("when checking the assignment of the field\n~s (at ~s)\nto the old value ~s and the new value\n~s\n",
                [pp_typed("  ", {lvalue, [], LV}, FieldType),
                 pp_loc(Fld),
                 pp(Id),
                 pp_typed("  ", E, InferredType)]);
        {field, _Ann, LV, E} ->
            io_lib:format("when checking the assignment of the field\n~s (at ~s)\nto the value\n~s\n",
                [pp_typed("  ", {lvalue, [], LV}, FieldType),
                 pp_loc(Fld),
                 pp_typed("  ", E, InferredType)]);
        {proj, _Ann, _Rec, _Fld} ->
            io_lib:format("when checking the record projection at ~s\n~s\nagainst the expected type\n~s\n",
                [pp_loc(Fld),
                 pp_typed("  ", Fld, FieldType),
                 pp_type("  ", InferredType)])
    end;
pp_when({record_constraint, RecType0, InferredType0, Fld}) ->
    RecType      = instantiate(RecType0),
    InferredType = instantiate(InferredType0),
    case Fld of
        {field, _Ann, _LV, _Id, _E} ->
            io_lib:format("when checking that the record type\n~s\n~s\n"
                          "matches the expected type\n~s\n",
                [pp_type("  ", RecType),
                 pp_why_record(Fld),
                 pp_type("  ", InferredType)]);
        {field, _Ann, _LV, _E} ->
            io_lib:format("when checking that the record type\n~s\n~s\n"
                          "matches the expected type\n~s\n",
                [pp_type("  ", RecType),
                 pp_why_record(Fld),
                 pp_type("  ", InferredType)]);
        {proj, _Ann, Rec, _FldName} ->
            io_lib:format("when checking that the expression\n~s (at ~s)\nhas type\n~s\n~s\n",
                [pp_typed("  ", Rec, InferredType),
                 pp_loc(Rec),
                 pp_type("  ", RecType),
                 pp_why_record(Fld)])
    end;
pp_when({if_branches, Then, ThenType0, Else, ElseType0}) ->
    {ThenType, ElseType} = instantiate({ThenType0, ElseType0}),
    Branches = [ {Then, ThenType} | [ {B, ElseType} || B <- if_branches(Else) ] ],
    io_lib:format("when comparing the types of the if-branches\n"
                  "~s", [ [ io_lib:format("~s (at ~s)\n", [pp_typed("  - ", B, BType), pp_loc(B)])
                          || {B, BType} <- Branches ] ]);
pp_when({case_pat, Pat, PatType0, ExprType0}) ->
    {PatType, ExprType} = instantiate({PatType0, ExprType0}),
    io_lib:format("when checking the type of the pattern at ~s\n~s\n"
                  "against the expected type\n~s\n",
                  [pp_loc(Pat), pp_typed("  ", Pat, PatType),
                   pp_type("  ", ExprType)]);
pp_when({check_expr, Expr, Inferred0, Expected0}) ->
    {Inferred, Expected} = instantiate({Inferred0, Expected0}),
    io_lib:format("when checking the type of the expression at ~s\n~s\n"
                  "against the expected type\n~s\n",
                  [pp_loc(Expr), pp_typed("  ", Expr, Inferred),
                   pp_type("  ", Expected)]);
pp_when({checking_init_type, Ann}) ->
    io_lib:format("when checking that 'init' returns a value of type 'state' at ~s\n",
                  [pp_loc(Ann)]);
pp_when(unknown) -> "".

-spec pp_why_record(why_record()) -> iolist().
pp_why_record(Fld = {field, _Ann, LV, _Id, _E}) ->
    io_lib:format("arising from an assignment of the field ~s (at ~s)",
        [pp_expr("", {lvalue, [], LV}),
         pp_loc(Fld)]);
pp_why_record(Fld = {field, _Ann, LV, _E}) ->
    io_lib:format("arising from an assignment of the field ~s (at ~s)",
        [pp_expr("", {lvalue, [], LV}),
         pp_loc(Fld)]);
pp_why_record({proj, _Ann, Rec, FldName}) ->
    io_lib:format("arising from the projection of the field ~s (at ~s)",
        [pp(FldName),
         pp_loc(Rec)]).


if_branches(If = {'if', Ann, _, Then, Else}) ->
    case proplists:get_value(format, Ann) of
        elif -> [Then | if_branches(Else)];
        _    -> [If]
    end;
if_branches(E) -> [E].

pp_typed(Label, E, T = {type_sig, _, _, _, _}) -> pp_typed(Label, E, typesig_to_fun_t(T));
pp_typed(Label, {typed, _, Expr, _}, Type) ->
    pp_typed(Label, Expr, Type);
pp_typed(Label, Expr, Type) ->
    pp_expr(Label, {typed, [], Expr, Type}).

pp_expr(Label, Expr) ->
    prettypr:format(prettypr:beside(prettypr:text(Label), aeso_pretty:expr(Expr, [show_generated]))).

pp_type(Label, Type) ->
    prettypr:format(prettypr:beside(prettypr:text(Label), aeso_pretty:type(Type, [show_generated]))).

line_number(T)   -> aeso_syntax:get_ann(line, T, 0).
column_number(T) -> aeso_syntax:get_ann(col, T, 0).

loc(T) ->
    {line_number(T), column_number(T)}.

pp_loc(T) ->
    {Line, Col} = loc(T),
    case {Line, Col} of
        {0, 0} -> "(builtin location)";
        _      -> io_lib:format("line ~p, column ~p", [Line, Col])
    end.

pp(T = {type_sig, _, _, _, _}) ->
    pp(typesig_to_fun_t(T));
pp([]) ->
    "";
pp([T]) ->
    pp(T);
pp([T|Ts]) ->
    [pp(T), ", "|pp(Ts)];
pp({id, _, Name}) ->
    Name;
pp({qid, _, Name}) ->
    string:join(Name, ".");
pp({con, _, Name}) ->
    Name;
pp({uvar, _, Ref}) ->
    %% Show some unique representation
    ["?u" | integer_to_list(erlang:phash2(Ref, 16384)) ];
pp({tvar, _, Name}) ->
    Name;
pp({tuple_t, _, Cpts}) ->
    ["(", pp(Cpts), ")"];
pp({app_t, _, T, []}) ->
    pp(T);
pp({app_t, _, {id, _, Name}, Args}) ->
    [Name, "(", pp(Args), ")"];
pp({named_arg_t, _, Name, Type, Default}) ->
    [pp(Name), " : ", pp(Type), " = ", pp(Default)];
pp({fun_t, _, Named = {uvar, _, _}, As, B}) ->
    ["(", pp(Named), " | ", pp(As), ") => ", pp(B)];
pp({fun_t, _, Named, As, B}) when is_list(Named) ->
    ["(", pp(Named ++ As), ") => ", pp(B)].

%% -- Pre-type checking desugaring -------------------------------------------

%% Desugars nested record/map updates as follows:
%%  { x.y = v1, x.z @ z = f(z) } becomes { x @ __x = __x { y = v1, z @ z = f(z) } }
%%  { [k1].x = v1, [k2].y = v2 } becomes { [k1] @ __x = __x { x = v1 }, [k2] @ __x = __x { y = v2 } }
%% There's no comparison of k1 and k2 to group the updates if they are equal.
desugar({record, Ann, Rec, Updates}) ->
    {record, Ann, Rec, desugar_updates(Updates)};
desugar({map, Ann, Map, Updates}) ->
    {map, Ann, Map, desugar_updates(Updates)};
desugar([H|T]) ->
  [desugar(H) | desugar(T)];
desugar(T) when is_tuple(T) ->
  list_to_tuple(desugar(tuple_to_list(T)));
desugar(X) -> X.

desugar_updates([]) -> [];
desugar_updates([Upd | Updates]) ->
    {Key, MakeField, Rest} = update_key(Upd),
    {More, Updates1}       = updates_key(Key, Updates),
    %% Check conflicts
    case length([ [] || [] <- [Rest | More] ]) of
        N when N > 1 -> error({conflicting_updates_for_field, Upd, Key});
        _ -> ok
    end,
    [MakeField(lists:append([Rest | More])) | desugar_updates(Updates1)].

%% TODO: refactor representation to make this not horrible
update_key(Fld = {field, _, [Elim], _}) ->
    {elim_key(Elim), fun(_) -> Fld end, []};
update_key(Fld = {field, _, [Elim], _, _}) ->
    {elim_key(Elim), fun(_) -> Fld end, []};
update_key({field, Ann, [P = {proj, _, {id, _, Name}} | Rest], Value}) ->
    {Name, fun(Flds) -> {field, Ann, [P], {id, [], "__x"},
                            desugar(map_or_record(Ann, {id, [], "__x"}, Flds))}
           end, [{field, Ann, Rest, Value}]};
update_key({field, Ann, [P = {proj, _, {id, _, Name}} | Rest], Id, Value}) ->
    {Name, fun(Flds) -> {field, Ann, [P], {id, [], "__x"},
                            desugar(map_or_record(Ann, {id, [], "__x"}, Flds))}
           end, [{field, Ann, Rest, Id, Value}]};
update_key({field, Ann, [K = {map_get, _, _} | Rest], Value}) ->
    {map_key, fun(Flds) -> {field, Ann, [K], {id, [], "__x"},
                            desugar(map_or_record(Ann, {id, [], "__x"}, Flds))}
              end, [{field, Ann, Rest, Value}]};
update_key({field, Ann, [K = {map_get, _, _, _} | Rest], Value}) ->
    {map_key, fun(Flds) -> {field, Ann, [K], {id, [], "__x"},
                            desugar(map_or_record(Ann, {id, [], "__x"}, Flds))}
              end, [{field, Ann, Rest, Value}]};
update_key({field, Ann, [K = {map_get, _, _, _} | Rest], Id, Value}) ->
    {map_key, fun(Flds) -> {field, Ann, [K], {id, [], "__x"},
                            desugar(map_or_record(Ann, {id, [], "__x"}, Flds))}
              end, [{field, Ann, Rest, Id, Value}]};
update_key({field, Ann, [K = {map_get, _, _} | Rest], Id, Value}) ->
    {map_key, fun(Flds) -> {field, Ann, [K], {id, [], "__x"},
                            desugar(map_or_record(Ann, {id, [], "__x"}, Flds))}
              end, [{field, Ann, Rest, Id, Value}]}.

map_or_record(Ann, Val, Flds = [Fld | _]) ->
    Kind = case element(3, Fld) of
             [{proj, _, _}       | _] -> record;
             [{map_get, _, _}    | _] -> map;
             [{map_get, _, _, _} | _] -> map
           end,
    {Kind, Ann, Val, Flds}.

elim_key({proj, _, {id, _, Name}}) -> Name;
elim_key({map_get, _, _, _})       -> map_key;  %% no grouping on map keys (yet)
elim_key({map_get, _, _})          -> map_key.

updates_key(map_key, Updates) -> {[], Updates};
updates_key(Name, Updates) ->
    Xs = [ {Upd, Name1 == Name, Rest}
           || Upd <- Updates,
              {Name1, _, Rest} <- [update_key(Upd)] ],
    Updates1 = [ Upd  || {Upd, false, _} <- Xs ],
    More     = [ Rest || {_, true, Rest} <- Xs ],
    {More, Updates1}.
