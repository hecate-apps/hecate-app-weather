%%% @doc Hecate Weather daemon application.
%%%
%%% Connects to the Macula mesh and advertises an RPC endpoint
%%% that returns real weather data from Open-Meteo.
%%% @end
-module(hecate_app_weatherd_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = ensure_inets(),
    app_weather_sup:start_link().

stop(_State) ->
    ok.

ensure_inets() ->
    case inets:start() of
        ok -> ok;
        {error, {already_started, inets}} -> ok
    end.
