// Minimal HTTP API (no dependencies).
//   GET /api/info  -> which version and which pod answered
//   GET /api/work  -> burns CPU (used by the "Generate load" button)
//   GET /healthz   -> liveness/readiness probe
const http = require("node:http");
const os = require("node:os");

const PORT = Number(process.env.PORT || 8080);
const VERSION = process.env.APP_VERSION || "dev";
const STARTED_AT = new Date().toISOString();
const WORK_MS = 100;

function send(res, status, body, type = "application/json") {
  res.writeHead(status, { "content-type": type, "cache-control": "no-store" });
  res.end(type === "application/json" ? JSON.stringify(body) : body);
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    return send(res, 200, "ok", "text/plain");
  }
  if (req.method === "GET" && req.url === "/api/info") {
    return send(res, 200, {
      service: "api",
      message: "Hello from the API, shipped with GitOps",
      version: VERSION,
      pod: os.hostname(),
      startedAt: STARTED_AT,
      time: new Date().toISOString(),
    });
  }
  if (req.method === "GET" && req.url === "/api/work") {
    // Burn ~100 ms of CPU, so a burst of calls drives the HPA to add pods.
    const start = Date.now();
    let x = 0;
    while (Date.now() - start < WORK_MS) x += Math.sqrt(x + 1);
    return send(res, 200, { pod: os.hostname(), version: VERSION, workMs: WORK_MS });
  }
  send(res, 404, { error: "not found" });
});

server.listen(PORT, () => console.log(`api ${VERSION} listening on :${PORT}`));

// Let Kubernetes stop the pod cleanly during rollouts.
process.on("SIGTERM", () => server.close(() => process.exit(0)));
