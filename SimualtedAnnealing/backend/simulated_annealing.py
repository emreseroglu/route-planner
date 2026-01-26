import random
import math
from typing import List, Dict, Tuple
import openrouteservice 

# ==========================
# 🔑 API KEY
# ==========================
API_KEY = "eyJvcmciOiI1YjNjZTM1OTc4NTExMTAwMDFjZjYyNDgiLCJpZCI6Ijg1YjY0MjA5NWU1MDRkNzRhYWM1OTVmODE4Yjk0YjliIiwiaCI6Im11cm11cjY0In0="
client = openrouteservice.Client(key=API_KEY)

# ==========================
# ⚡ MATRIX FONKSİYONU
# ==========================
def build_distance_matrix(points: List[Dict[str, float]], mode: str = "driving-car") -> List[List[float]]:
    coordinates = [[p["lng"], p["lat"]] for p in points]
    
    api_mode = mode
    if mode == "driving":
        api_mode = "driving-car"
    elif mode == "walking":
        api_mode = "foot-walking"
    
    print(f"📡 API İsteği: {len(points)} Durak, Mod: {api_mode}")

    try:
        matrix_response = client.distance_matrix(
            locations=coordinates,
            profile=api_mode, 
            metrics=["distance"], 
            units="m" 
        )
        dist_matrix = matrix_response['distances']
        MAX_DIST = 99999999.0 
        n = len(dist_matrix)
        for i in range(n):
            for j in range(n):
                if dist_matrix[i][j] is None:
                    dist_matrix[i][j] = MAX_DIST
        return dist_matrix
    except Exception as e:
        print(f"❌ Matrix API Hatası: {e}")
        n = len(points)
        return [[99999999.0] * n for _ in range(n)]

# ==========================
# 🔥 Simulated Annealing (SADELEŞTİRİLMİŞ)
# ==========================
class SimulatedAnnealingTSP:
    def __init__(
        self,
        points: List[Dict[str, float]],
        initial_temp: float = 10000.0,
        cooling_rate: float = 0.995,
        stopping_temp: float = 0.1,
        max_iter: int = 200000,
        mode: str = "driving-car"
    ):
        if len(points) < 2:
            raise ValueError("TSP için en az 2 nokta gerekir.")

        self.points = [dict(p) for p in points]
        self.n = len(self.points)
        self.mode = mode
        self.dist_matrix = build_distance_matrix(self.points, mode=self.mode)

        other_indices = list(range(1, self.n))
        random.shuffle(other_indices)
        self.current = [0] + other_indices 
        self.best = list(self.current)

        self.temp = initial_temp
        self.alpha = cooling_rate
        self.stopping_temp = stopping_temp
        self.max_iter = max_iter

        self.current_distance = self._distance_of(self.current)
        self.best_distance = self.current_distance

    def _make_candidate(self) -> List[int]:
        cand = list(self.current)
        if self.n > 2:
            i, j = random.sample(range(1, self.n), 2)
            cand[i], cand[j] = cand[j], cand[i]
        return cand

    def _distance_of(self, seq: List[int]) -> float:
        dist = 0.0
        for i in range(len(seq) - 1):
            dist += self.dist_matrix[seq[i]][seq[i+1]]
        return dist

    def run(self) -> Tuple[List[Dict[str, float]], float]:
        it = 0
        while self.temp > self.stopping_temp and it < self.max_iter:
            candidate = self._make_candidate()
            cand_dist = self._distance_of(candidate)
            delta = cand_dist - self.current_distance

            if delta < 0 or math.exp(-delta / self.temp) > random.random():
                self.current = candidate
                self.current_distance = cand_dist
                if cand_dist < self.best_distance:
                    self.best = list(candidate)
                    self.best_distance = cand_dist

            self.temp *= self.alpha
            it += 1

        best_route = [self.points[i] for i in self.best]
        return best_route, self.best_distance