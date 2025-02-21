-module(wapi_residence).

-type response_data() :: wapi_handler_utils:response_data().

-export([get/1]).

-type id() :: binary().
-type residence() :: #{
    id := id(),
    name := binary(),
    flag => binary()
}.

-export_type([id/0]).
-export_type([residence/0]).

%%

-spec get(id()) -> {ok, response_data()} | {error, notfound}.
get(ID) ->
    get_residence(genlib_string:to_lower(ID)).

get_residence(<<"rus">> = ID) ->
    {ok, #{
        <<"id">> => genlib_string:to_upper(ID),
        <<"name">> => <<"Российская федерация"/utf8>>,
        <<"flag">> => <<"🇷🇺"/utf8>>
    }};
get_residence(_) ->
    {error, notfound}.
