%%% @doc ETS-backed weather cache with TTL eviction.
%%%
%%% Caches Open-Meteo responses keyed by rounded lat/lng (1 decimal place).
%%% Nearby locations (within ~11km) share a cache entry.
%%%
%%% Periodic cleanup every 5 minutes removes entries older than TTL.
%%% @end
-module(app_weather_cache).
-behaviour(gen_server).

-export([start_link/0, get/2, put/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(ETS_TABLE, weather_cache).
-define(CLEANUP_INTERVAL_MS, 300_000).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Look up cached weather for a location. Returns {ok, Data} or miss.
-spec get(float(), float()) -> {ok, map()} | miss.
get(Lat, Lng) ->
    Key = cache_key(Lat, Lng),
    TTL = ttl_seconds(),
    Now = erlang:system_time(second),
    case ets:lookup(?ETS_TABLE, Key) of
        [{Key, Data, InsertedAt}] when Now - InsertedAt < TTL ->
            {ok, Data};
        _ ->
            miss
    end.

%% @doc Cache a weather response for a location.
-spec put(float(), float(), map()) -> ok.
put(Lat, Lng, Data) ->
    Key = cache_key(Lat, Lng),
    Now = erlang:system_time(second),
    ets:insert(?ETS_TABLE, {Key, Data, Now}),
    ok.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ets:new(?ETS_TABLE, [named_table, set, public, {read_concurrency, true}]),
    schedule_cleanup(),
    logger:info("[app_weather_cache] Started (TTL: ~bs)", [ttl_seconds()]),
    {ok, #{}}.

handle_call(_Msg, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    Now = erlang:system_time(second),
    TTL = ttl_seconds(),
    %% Delete all entries older than TTL
    Expired = ets:foldl(fun({Key, _Data, InsertedAt}, Acc) ->
        case Now - InsertedAt >= TTL of
            true -> [Key | Acc];
            false -> Acc
        end
    end, [], ?ETS_TABLE),
    lists:foreach(fun(Key) -> ets:delete(?ETS_TABLE, Key) end, Expired),
    case Expired of
        [] -> ok;
        _ -> logger:info("[app_weather_cache] Evicted ~b stale entries", [length(Expired)])
    end,
    schedule_cleanup(),
    {noreply, State};

handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

%% Round to 1 decimal place (~11km grid). Nearby stubs share cache entries.
cache_key(Lat, Lng) ->
    RLat = round(Lat * 10) / 10,
    RLng = round(Lng * 10) / 10,
    {RLat, RLng}.

ttl_seconds() ->
    application:get_env(hecate_app_weatherd, cache_ttl_seconds, 900).

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), cleanup).
