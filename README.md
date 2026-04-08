# hecate-app-weather

Mesh-native weather microstation service. Wraps the [Open-Meteo](https://open-meteo.com/) weather API as a Macula mesh RPC endpoint, enabling any node on the mesh to fetch real weather data for any location.

## Architecture

```
Any mesh node (stub, daemon, app)
  │
  └─ RPC: io.hecate.weather.get_current({lat: 52.52, lng: 13.41})
       │
       ↓ (routed via DHT)
  hecate-app-weather daemon
       │
       ├─ ETS cache hit? → return cached
       │
       └─ cache miss → GET api.open-meteo.com/v1/forecast?...
                         │
                         └─ cache result (15min TTL), return
```

## RPC Endpoint

**Procedure:** `io.hecate.weather.get_current`

**Request:**
```json
{"lat": 52.52, "lng": 13.41}
```

**Response:**
```json
{
  "temperature_c": 14.2,
  "humidity_pct": 72,
  "wind_kmh": 18.5,
  "wind_direction_deg": 230,
  "weather_code": 2,
  "conditions": "partly_cloudy",
  "is_day": true,
  "source": "open-meteo.com"
}
```

## Caching

Responses are cached in ETS with a 15-minute TTL, keyed by rounded lat/lng (1 decimal place, ~11km grid). Nearby locations share cache entries.

With 2000 stubs polling every 15 minutes, actual Open-Meteo API requests are ~200/day (geographic deduplication), well within the 10,000/day fair use policy.

## Configuration

| Env Variable | Default | Description |
|-------------|---------|-------------|
| `OPEN_METEO_URL` | `https://api.open-meteo.com` | Open-Meteo API base URL |
| `MACULA_RELAYS` | (from daemon) | Relay URLs for mesh connectivity |

## Attribution

Weather data by [Open-Meteo.com](https://open-meteo.com/) — free for non-commercial use.
Data licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## License

Apache-2.0
