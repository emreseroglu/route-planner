from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from typing import List, Optional
from fastapi.middleware.cors import CORSMiddleware
from simulated_annealing import SimulatedAnnealingTSP
import uvicorn

app = FastAPI(title="TSP-SA Route Optimizer (Standard)")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class Location(BaseModel):
    lat: float
    lng: float
    name: Optional[str] = None

class OptimizeRequest(BaseModel):
    locations: List[Location] = Field(..., min_items=2)
    initial_temp: Optional[float] = 10000.0
    cooling_rate: Optional[float] = 0.995
    stopping_temp: Optional[float] = 0.1
    max_iter: Optional[int] = 200000
    transport_mode: Optional[str] = "driving-car"

class OptimizeResponse(BaseModel):
    route: List[Location]
    distance_meters: float

@app.post("/route", response_model=OptimizeResponse)
def optimize_route(req: OptimizeRequest):
    pts = [loc.dict() for loc in req.locations]
    print(f"📥 İstek: {len(pts)} Durak, Mod: {req.transport_mode}")

    try:
        sa = SimulatedAnnealingTSP(
            points=pts,
            initial_temp=req.initial_temp,
            cooling_rate=req.cooling_rate,
            stopping_temp=req.stopping_temp,
            max_iter=req.max_iter,
            mode=req.transport_mode
        )
        best_loop, dist_m = sa.run()
    except Exception as e:
        print(f"🔥 Hata: {e}")
        raise HTTPException(status_code=400, detail=str(e))

    route = [{"lat": p["lat"], "lng": p["lng"], "name": p.get("name")} for p in best_loop]
    return {"route": route, "distance_meters": dist_m}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)