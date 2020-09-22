%%%
%%% Instrument
%%%
%%% TODOs
%%%
%%%  - We must consider withdrawal provider terms ensure that the provided
%%%    resource is ok to withdraw to.
%%%

-module(ff_instrument).

-type id()          :: binary().
-type external_id() :: id() | undefined.
-type name()        :: binary().
-type metadata()    :: ff_entity_context:md().
-type resource(T)   :: T.
-type account()     :: ff_account:account().
-type identity()    :: ff_identity:id().
-type currency()    :: ff_currency:id().
-type timestamp()   :: ff_time:timestamp_ms().
-type status()      :: unauthorized | authorized.

-define(ACTUAL_FORMAT_VERSION, 4).
-type instrument_state(T) :: #{
    account     := account() | undefined,
    resource    := resource(T),
    name        := name(),
    status      := status() | undefined,
    created_at  => timestamp(),
    external_id => id(),
    metadata    => metadata()
}.

-type instrument(T) :: #{
    version     := ?ACTUAL_FORMAT_VERSION,
    resource    := resource(T),
    name        := name(),
    created_at  => timestamp(),
    external_id => id(),
    metadata    => metadata()
}.

-type event(T) ::
    {created, instrument_state(T)} |
    {account, ff_account:event()} |
    {status_changed, status()}.

-type legacy_event() :: any().

-type create_error() ::
    {identity, notfound} |
    {currecy, notfoud} |
    ff_account:create_error() |
    {identity, ff_party:inaccessibility()}.

-export_type([id/0]).
-export_type([instrument/1]).
-export_type([instrument_state/1]).
-export_type([status/0]).
-export_type([resource/1]).
-export_type([event/1]).
-export_type([name/0]).
-export_type([metadata/0]).

-export([account/1]).

-export([id/1]).
-export([name/1]).
-export([identity/1]).
-export([currency/1]).
-export([resource/1]).
-export([status/1]).
-export([external_id/1]).
-export([created_at/1]).
-export([metadata/1]).

-export([create/1]).
-export([authorize/1]).

-export([is_accessible/1]).

-export([apply_event/2]).
-export([maybe_migrate/2]).
-export([maybe_migrate_resource/1]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1, unwrap/2]).

%% Accessors

-spec account(instrument_state(_)) ->
    account() | undefined.

account(#{account := V}) ->
    V;
account(_) ->
    undefined.

-spec id(instrument_state(_)) ->
    id().
-spec name(instrument_state(_)) ->
    binary().
-spec identity(instrument_state(_)) ->
    identity().
-spec currency(instrument_state(_)) ->
    currency().
-spec resource(instrument_state(T)) ->
    resource(T).
-spec status(instrument_state(_)) ->
    status() | undefined.

id(Instrument) ->
    case account(Instrument) of
        undefined ->
            undefined;
        Account ->
            ff_account:id(Account)
    end.
name(#{name := V}) ->
    V.
identity(Instrument) ->
    ff_account:identity(account(Instrument)).
currency(Instrument) ->
    ff_account:currency(account(Instrument)).
resource(#{resource := V}) ->
    V.
status(#{status := V}) ->
    V;
status(_) ->
    undefined.

-spec external_id(instrument_state(_)) ->
    external_id().

external_id(#{external_id := ExternalID}) ->
    ExternalID;
external_id(_Instrument) ->
    undefined.

-spec created_at(instrument_state(_)) ->
    timestamp().

created_at(#{created_at := CreatedAt}) ->
    CreatedAt.

-spec metadata(instrument_state(_)) ->
    metadata().

metadata(#{metadata := Metadata}) ->
    Metadata;
metadata(_Instrument) ->
    undefined.

%%

-spec create(ff_instrument_machine:params(T)) ->
    {ok, [event(T)]} |
    {error, create_error()}.

create(Params = #{
    id := ID,
    identity := IdentityID,
    name := Name,
    currency := CurrencyID,
    resource := Resource
}) ->
    do(fun () ->
        Identity = ff_identity_machine:identity(unwrap(identity, ff_identity_machine:get(IdentityID))),
        Currency = unwrap(currency, ff_currency:get(CurrencyID)),
        Events = unwrap(ff_account:create(ID, Identity, Currency)),
        accessible = unwrap(identity, ff_identity:is_accessible(Identity)),
        CreatedAt = ff_time:now(),
        [{created, genlib_map:compact(#{
            version => ?ACTUAL_FORMAT_VERSION,
            name => Name,
            resource => Resource,
            external_id => maps:get(external_id, Params, undefined),
            metadata => maps:get(metadata, Params, undefined),
            created_at => CreatedAt
        })}] ++
        [{account, Ev} || Ev <- Events] ++
        [{status_changed, unauthorized}]
    end).

-spec authorize(instrument_state(T)) ->
    {ok, [event(T)]}.

authorize(#{status := unauthorized}) ->
    % TODO
    %  - Do the actual authorization
    {ok, [{status_changed, authorized}]};
authorize(#{status := authorized}) ->
    {ok, []}.

-spec is_accessible(instrument_state(_)) ->
    {ok, accessible} |
    {error, ff_party:inaccessibility()}.

is_accessible(Instrument) ->
    ff_account:is_accessible(account(Instrument)).

%%

-spec apply_event(event(T), ff_maybe:maybe(instrument_state(T))) ->
    instrument_state(T).

apply_event({created, Instrument}, undefined) ->
    Instrument;
apply_event({status_changed, S}, Instrument) ->
    Instrument#{status => S};
apply_event({account, Ev}, Instrument = #{account := Account}) ->
    Instrument#{account => ff_account:apply_event(Ev, Account)};
apply_event({account, Ev}, Instrument) ->
    apply_event({account, Ev}, Instrument#{account => undefined}).

-spec maybe_migrate(event(T) | legacy_event(), ff_machine:migrate_params()) ->
    event(T).

maybe_migrate(Event = {created, #{version := ?ACTUAL_FORMAT_VERSION}}, _MigrateParams) ->
    Event;
maybe_migrate({created, Instrument = #{version := 3, name := Name}}, MigrateParams) ->
    maybe_migrate({created, Instrument#{
        version => 4,
        name => maybe_migrate_name(Name)
    }}, MigrateParams);
maybe_migrate({created, Instrument = #{version := 2}}, MigrateParams) ->
    Context = maps:get(ctx, MigrateParams, undefined),
    %% TODO add metada migration for eventsink after decouple instruments
    Metadata = ff_entity_context:try_get_legacy_metadata(Context),
    maybe_migrate({created, genlib_map:compact(Instrument#{
        version => 3,
        metadata => Metadata
    })}, MigrateParams);
maybe_migrate({created, Instrument = #{version := 1}}, MigrateParams) ->
    Timestamp = maps:get(timestamp, MigrateParams),
    CreatedAt = ff_codec:unmarshal(timestamp_ms, ff_codec:marshal(timestamp, Timestamp)),
    maybe_migrate({created, Instrument#{
        version => 2,
        created_at => CreatedAt
    }}, MigrateParams);
maybe_migrate({created, Instrument = #{
        resource    := Resource,
        name        := Name
}}, MigrateParams) ->
    NewInstrument = genlib_map:compact(#{
        version     => 1,
        resource    => maybe_migrate_resource(Resource),
        name        => Name,
        external_id => maps:get(external_id, Instrument, undefined)
    }),
    maybe_migrate({created, NewInstrument}, MigrateParams);

%% Other events
maybe_migrate(Event, _MigrateParams) ->
    Event.

-spec maybe_migrate_resource(any()) ->
    any().

maybe_migrate_resource({crypto_wallet, #{id := ID, currency := ripple, tag := Tag}}) ->
    maybe_migrate_resource({crypto_wallet, #{id => ID, currency => {ripple, #{tag => Tag}}}});
maybe_migrate_resource({crypto_wallet, #{id := ID, currency := Currency}}) when is_atom(Currency) ->
    maybe_migrate_resource({crypto_wallet, #{id => ID, currency => {Currency, #{}}}});

maybe_migrate_resource({crypto_wallet, #{id := _ID} = CryptoWallet}) ->
    maybe_migrate_resource({crypto_wallet, #{crypto_wallet => CryptoWallet}});
maybe_migrate_resource({bank_card, #{token := _Token} = BankCard}) ->
    maybe_migrate_resource({bank_card, #{bank_card => BankCard}});

maybe_migrate_resource(Resource) ->
    Resource.

maybe_migrate_name(Name) ->
    re:replace(Name, "\\d{12,19}", <<"">>, [global, {return, binary}]).

%% Tests

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-spec test() -> _.

-spec v1_created_migration_test() -> _.
v1_created_migration_test() ->
    CreatedAt = ff_time:now(),
    LegacyEvent = {created, #{
        version     => 1,
        resource    => {crypto_wallet, #{crypto_wallet => #{}}},
        name        => <<"some name">>,
        external_id => genlib:unique()
    }},
    {created, #{version := Version}} = maybe_migrate(LegacyEvent, #{
        timestamp => ff_codec:unmarshal(timestamp, ff_codec:marshal(timestamp_ms, CreatedAt))
    }),
    ?assertEqual(4, Version).

-spec v2_created_migration_test() -> _.
v2_created_migration_test() ->
    CreatedAt = ff_time:now(),
    LegacyEvent = {created, #{
        version => 2,
        resource    => {crypto_wallet, #{crypto_wallet => #{}}},
        name        => <<"some name">>,
        external_id => genlib:unique(),
        created_at  => CreatedAt
    }},
    {created, #{version := Version, metadata := Metadata}} = maybe_migrate(LegacyEvent, #{
        ctx => #{
            <<"com.rbkmoney.wapi">> => #{
                <<"metadata">> => #{
                    <<"some key">> => <<"some val">>
                }
            }
        }
    }),
    ?assertEqual(4, Version),
    ?assertEqual(#{<<"some key">> => <<"some val">>}, Metadata).

-spec name_migration_test() -> _.
name_migration_test() ->
    ?assertEqual(<<"sd">>, maybe_migrate_name(<<"sd123123123123123">>)),
    ?assertEqual(<<"sd1231231231sd23123">>, maybe_migrate_name(<<"sd1231231231sd23123">>)),
    ?assertEqual(<<"sdds123sd">>, maybe_migrate_name(<<"sd123123123123ds123sd">>)),
    ?assertEqual(<<"sdsd">>, maybe_migrate_name(<<"sd123123123123123sd">>)),
    ?assertEqual(<<"sd">>, maybe_migrate_name(<<"123123123123123sd">>)).

-endif.
