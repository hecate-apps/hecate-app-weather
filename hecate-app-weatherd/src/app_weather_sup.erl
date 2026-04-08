%%% @doc Top-level supervisor for the Weather daemon.
%%%
%%% Supervises:
%%%   - app_weather_cache: ETS-backed weather cache with TTL
%%%   - app_weather_rpc:   Mesh RPC responder for io.hecate.weather.get_current
%%% @end
-module(app_weather_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 60},
    Children = [
        #{id => app_weather_cache,
          start => {app_weather_cache, start_link, []},
          restart => permanent, type => worker},
        #{id => app_weather_rpc,
          start => {app_weather_rpc, start_link, []},
          restart => permanent, type => worker}
    ],
    {ok, {SupFlags, Children}}.
