%%% @doc Mesh RPC responder for weather data.
%%%
%%% Advertises `io.hecate.weather.get_current` on the mesh.
%%% When called, checks cache first, then fetches from Open-Meteo API.
%%%
%%% Request:  #{lat => float(), lng => float()}
%%% Response: #{temperature_c => float(), humidity_pct => float(),
%%%             wind_kmh => float(), wind_direction_deg => integer(),
%%%             weather_code => integer(), conditions => binary(),
%%%             is_day => boolean(), source => <<"open-meteo.com">>}
%%% @end
-module(app_weather_rpc).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(RETRY_INTERVAL_MS, 10_000).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    self() ! connect,
    {ok, #{client => undefined, advertised => false}}.

handle_call(_Msg, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(connect, State) ->
    Relays = relay_urls(),
    Realm = realm(),
    Identity = identity(),
    logger:info("[app_weather_rpc] Connecting to mesh (realm: ~s, relays: ~p)",
                [Realm, Relays]),
    case macula_relay_client:start_link(#{
        relays => Relays,
        realm => Realm,
        identity => Identity,
        type => <<"service">>
    }) of
        {ok, Client} ->
            logger:info("[app_weather_rpc] Connected to relay mesh"),
            erlang:monitor(process, Client),
            self() ! {advertise, Client},
            {noreply, State#{client => Client}};
        {error, Reason} ->
            logger:warning("[app_weather_rpc] Connect failed: ~p, retrying", [Reason]),
            erlang:send_after(?RETRY_INTERVAL_MS, self(), connect),
            {noreply, State}
    end;

handle_info({advertise, Client}, State) ->
    Procedure = rpc_procedure(),
    Handler = fun(Args) ->
        Result = handle_weather_request(Args),
        iolist_to_binary(json:encode(Result))
    end,
    case macula_relay_client:advertise(Client, Procedure, Handler) of
        {ok, _Ref} ->
            logger:info("[app_weather_rpc] Advertised ~s on mesh", [Procedure]),
            {noreply, State#{advertised => true}};
        {error, Reason} ->
            logger:warning("[app_weather_rpc] Advertise failed: ~p, retrying", [Reason]),
            erlang:send_after(?RETRY_INTERVAL_MS, self(), {advertise, Client}),
            {noreply, State}
    end;

handle_info({'DOWN', _Ref, process, _Pid, Reason}, State) ->
    logger:warning("[app_weather_rpc] Relay client died: ~p, reconnecting", [Reason]),
    erlang:send_after(?RETRY_INTERVAL_MS, self(), connect),
    {noreply, State#{client => undefined, advertised => false}};

handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% RPC Handler
%%====================================================================

handle_weather_request(Args) when is_map(Args) ->
    Lat = to_float(maps:get(<<"lat">>, Args, maps:get(lat, Args, undefined))),
    Lng = to_float(maps:get(<<"lng">>, Args, maps:get(lng, Args, undefined))),
    case {Lat, Lng} of
        {undefined, _} -> #{error => <<"missing lat">>};
        {_, undefined} -> #{error => <<"missing lng">>};
        {L, G} -> fetch_weather(L, G)
    end;
handle_weather_request(Args) when is_binary(Args) ->
    %% Relay may pass args as JSON binary — decode and retry
    try json:decode(Args) of
        Map when is_map(Map) -> handle_weather_request(Map);
        _ -> #{error => <<"expected JSON object with lat/lng">>}
    catch _:_ ->
        #{error => <<"invalid JSON">>}
    end;
handle_weather_request(Args) when is_list(Args) ->
    %% May arrive as proplist from some relay versions
    handle_weather_request(maps:from_list(Args));
handle_weather_request(_) ->
    #{error => <<"expected map with lat/lng">>}.

fetch_weather(Lat, Lng) ->
    case app_weather_cache:get(Lat, Lng) of
        {ok, Cached} ->
            Cached;
        miss ->
            case fetch_from_open_meteo(Lat, Lng) of
                {ok, Data} ->
                    app_weather_cache:put(Lat, Lng, Data),
                    Data;
                {error, Reason} ->
                    logger:warning("[app_weather_rpc] Open-Meteo fetch failed: ~p", [Reason]),
                    #{error => <<"weather_fetch_failed">>}
            end
    end.

%%====================================================================
%% Open-Meteo HTTP Client
%%====================================================================

%% All current fields we request from Open-Meteo.
%% These feed both the weather display AND the synthetic energy model.
-define(CURRENT_FIELDS,
    "temperature_2m,relative_humidity_2m,apparent_temperature,"
    "precipitation,rain,showers,snowfall,"
    "cloud_cover,pressure_msl,surface_pressure,"
    "wind_speed_10m,wind_direction_10m,wind_gusts_10m,"
    "weather_code,is_day,uv_index,visibility").

fetch_from_open_meteo(Lat, Lng) ->
    BaseUrl = open_meteo_url(),
    Url = lists:flatten(io_lib:format(
        "~s/v1/forecast?latitude=~.4f&longitude=~.4f&current=~s",
        [BaseUrl, Lat, Lng, ?CURRENT_FIELDS])),
    case httpc:request(get, {Url, []},
                       [{timeout, 10_000}, {ssl, [{verify, verify_none}]}], []) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            parse_open_meteo_response(Body);
        {ok, {{_, Code, _}, _, _}} ->
            {error, {http_status, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

parse_open_meteo_response(Body) ->
    try
        Json = json:decode(iolist_to_binary(Body)),
        Current = maps:get(<<"current">>, Json, #{}),
        F = fun(Key) -> maps:get(Key, Current, null) end,
        Data = #{
            %% Core weather
            temperature_c        => F(<<"temperature_2m">>),
            apparent_temperature_c => F(<<"apparent_temperature">>),
            humidity_pct         => F(<<"relative_humidity_2m">>),
            weather_code         => F(<<"weather_code">>),
            conditions           => weather_code_to_conditions(F(<<"weather_code">>)),
            is_day               => F(<<"is_day">>) =:= 1,
            %% Wind
            wind_kmh             => F(<<"wind_speed_10m">>),
            wind_direction_deg   => F(<<"wind_direction_10m">>),
            wind_gusts_kmh       => F(<<"wind_gusts_10m">>),
            %% Precipitation
            precipitation_mm     => F(<<"precipitation">>),
            rain_mm              => F(<<"rain">>),
            showers_mm           => F(<<"showers">>),
            snowfall_cm          => F(<<"snowfall">>),
            %% Atmosphere
            cloud_cover_pct      => F(<<"cloud_cover">>),
            pressure_hpa         => F(<<"pressure_msl">>),
            surface_pressure_hpa => F(<<"surface_pressure">>),
            visibility_m         => F(<<"visibility">>),
            uv_index             => F(<<"uv_index">>),
            %% Meta
            source               => <<"open-meteo.com">>
        },
        {ok, Data}
    catch
        _:Err ->
            {error, {json_parse, Err}}
    end.

%%====================================================================
%% WMO Weather Code → human-readable conditions
%%====================================================================

weather_code_to_conditions(0) -> <<"clear">>;
weather_code_to_conditions(1) -> <<"mainly_clear">>;
weather_code_to_conditions(2) -> <<"partly_cloudy">>;
weather_code_to_conditions(3) -> <<"overcast">>;
weather_code_to_conditions(45) -> <<"foggy">>;
weather_code_to_conditions(48) -> <<"foggy">>;
weather_code_to_conditions(C) when C >= 51, C =< 55 -> <<"drizzle">>;
weather_code_to_conditions(C) when C >= 56, C =< 57 -> <<"freezing_drizzle">>;
weather_code_to_conditions(C) when C >= 61, C =< 65 -> <<"rain">>;
weather_code_to_conditions(C) when C >= 66, C =< 67 -> <<"freezing_rain">>;
weather_code_to_conditions(C) when C >= 71, C =< 75 -> <<"snow">>;
weather_code_to_conditions(77) -> <<"snow_grains">>;
weather_code_to_conditions(C) when C >= 80, C =< 82 -> <<"rain_showers">>;
weather_code_to_conditions(C) when C >= 85, C =< 86 -> <<"snow_showers">>;
weather_code_to_conditions(95) -> <<"thunderstorm">>;
weather_code_to_conditions(C) when C >= 96, C =< 99 -> <<"thunderstorm_hail">>;
weather_code_to_conditions(_) -> <<"unknown">>.

%%====================================================================
%% Helpers
%%====================================================================

relay_urls() ->
    case os:getenv("MACULA_RELAYS") of
        false -> [<<"https://relay-de-nuremberg.macula.io:4433">>];
        Env -> [list_to_binary(string:trim(U))
                || U <- string:split(Env, ",", all),
                   string:trim(U) =/= ""]
    end.

realm() ->
    case os:getenv("MACULA_REALM") of
        false -> <<"io.macula">>;
        R -> list_to_binary(R)
    end.

identity() ->
    case os:getenv("WEATHER_IDENTITY") of
        false -> <<"hecate-app-weather">>;
        I -> list_to_binary(I)
    end.

rpc_procedure() ->
    case application:get_env(hecate_app_weatherd, rpc_procedure) of
        {ok, P} when is_list(P) -> list_to_binary(P);
        {ok, P} when is_binary(P) -> P;
        _ -> <<"io.hecate.weather.get_current">>
    end.

open_meteo_url() ->
    case os:getenv("OPEN_METEO_URL") of
        false ->
            case application:get_env(hecate_app_weatherd, open_meteo_url) of
                {ok, U} -> U;
                _ -> "https://api.open-meteo.com"
            end;
        Url -> Url
    end.

to_float(V) when is_float(V) -> V;
to_float(V) when is_integer(V) -> float(V);
to_float(V) when is_binary(V) ->
    try binary_to_float(V)
    catch error:badarg ->
        try float(binary_to_integer(V))
        catch error:badarg -> undefined
        end
    end;
to_float(V) when is_list(V) ->
    to_float(list_to_binary(V));
to_float(_) -> undefined.
