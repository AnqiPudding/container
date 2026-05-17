import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { AnimatePresence, motion } from "motion/react";
import {
  Activity,
  Box,
  Check,
  ChevronRight,
  Cloud,
  ExternalLink,
  Flame,
  Gauge,
  Github,
  Layers,
  Loader2,
  Play,
  RefreshCcw,
  Rocket,
  Square,
  Zap
} from "lucide-react";
import "./styles.css";

type AppStatus = {
  modalApp: string;
  image: string;
  gpu: string;
  build: {
    id: number | null;
    status: string;
    conclusion: string;
    url: string;
    progress: number;
  };
  endpoints: {
    comfyui: string;
    jupyter: string;
    control: string;
  };
  nodes: {
    baked: string[];
    pending: string[];
    runtime: string[];
  };
  auth: {
    github: boolean;
    modal: boolean;
    dockerSecrets: boolean;
  };
  app: {
    deployed: boolean;
    live: boolean;
    task?: {
      status: string;
      message: string;
    };
  };
  events: string[];
};

type Busy = "start" | "bake" | "deploy" | "scale" | "refresh" | "wd14" | null;

const emptyStatus: AppStatus = {
  modalApp: "modal-comfyui",
  image: "anqipudding/modal_comfyui:latest",
  gpu: "A10",
  build: { id: null, status: "unknown", conclusion: "", url: "", progress: 0 },
  endpoints: { comfyui: "", jupyter: "", control: "" },
  nodes: { baked: [], pending: [], runtime: [] },
  auth: { github: false, modal: false, dockerSecrets: false },
  app: { deployed: false, live: false, task: { status: "idle", message: "Ready" } },
  events: []
};

function App() {
  const [status, setStatus] = useState<AppStatus>(emptyStatus);
  const [busy, setBusy] = useState<Busy>(null);
  const [error, setError] = useState("");

  const setupSteps = [
    { key: "github", label: "Connect GitHub", detail: "Use GitHub CLI auth so the app can push bake commits and trigger Actions.", done: status.auth.github },
    { key: "modal", label: "Connect Modal", detail: "Select the Modal profile that owns your ComfyUI deployment.", done: status.auth.modal },
    { key: "docker", label: "Confirm Docker secrets", detail: "Store DOCKERHUB_USERNAME and DOCKERHUB_TOKEN in the GitHub repo secrets.", done: status.auth.dockerSecrets }
  ];
  const ready = setupSteps.every((step) => step.done);
  const nextStep = setupSteps.find((step) => !step.done);
  const actionBusy = busy !== null && busy !== "refresh";
  const activeNodes = useMemo(() => {
    const merged = new Set([...status.nodes.baked, ...status.nodes.pending, ...status.nodes.runtime]);
    return [...merged].sort((a, b) => a.localeCompare(b));
  }, [status.nodes]);

  async function refresh() {
    const res = await fetch("/api/status");
    if (!res.ok) throw new Error(await res.text());
    setStatus(await res.json());
  }

  async function act(action: Busy, path: string, body?: unknown) {
    setBusy(action);
    setError("");
    try {
      const res = await fetch(path, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: body ? JSON.stringify(body) : undefined
      });
      if (!res.ok) throw new Error(await res.text());
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(null);
    }
  }

  useEffect(() => {
    refresh().catch((err) => setError(err.message));
    const id = window.setInterval(() => refresh().catch(() => undefined), 5000);
    return () => window.clearInterval(id);
  }, []);

  return (
    <main className="shell">
      <section className="hero">
        <motion.div
          className="hero-copy"
          initial={{ opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
        >
          <div className="eyebrow"><Zap size={16} /> Comfy Launch Control</div>
          <h1>One control room for Modal ComfyUI.</h1>
          <p>
            Start the GPU, install nodes in ComfyUI, keep using the live session, and bake the next Docker image in the background.
          </p>
        </motion.div>
        <CommandVisual live={status.app.live} deployed={status.app.deployed} />
      </section>

      <section className="toolbar">
        <StatusPill icon={<Github size={16} />} label="GitHub" ok={status.auth.github} />
        <StatusPill icon={<Cloud size={16} />} label="Modal" ok={status.auth.modal} />
        <StatusPill icon={<Box size={16} />} label="Docker secrets" ok={status.auth.dockerSecrets} />
        <button className="ghost" onClick={() => act("refresh", "/api/refresh")} disabled={busy === "refresh"}>
          <RefreshCcw size={16} className={busy === "refresh" ? "spin" : ""} /> Refresh
        </button>
      </section>

      <AnimatePresence>
        {error && (
          <motion.div className="error" initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}>
            {error}
          </motion.div>
        )}
      </AnimatePresence>

      {!ready && (
        <section className="setup">
          <div>
            <div className="panel-title"><Rocket size={18} /><span>Guided Setup</span></div>
            <h2>{nextStep ? nextStep.label : "Ready"}</h2>
            <p>{nextStep?.detail}</p>
          </div>
          <div className="setup-steps">
            {setupSteps.map((step, index) => (
              <motion.div className={`setup-step ${step.done ? "done" : index === setupSteps.findIndex((item) => !item.done) ? "active" : ""}`} key={step.key}>
                {step.done ? <Check size={16} /> : <span>{index + 1}</span>}
                <strong>{step.label}</strong>
              </motion.div>
            ))}
          </div>
          <button className="primary" onClick={() => act("refresh", "/api/refresh")} disabled={busy === "refresh"}>
            {busy === "refresh" ? <Loader2 size={18} className="spin" /> : <RefreshCcw size={18} />} Check setup
          </button>
        </section>
      )}

      <section className="grid">
        <Panel className="span-7" title="Session" icon={<Activity size={18} />}>
          {status.app.task?.status !== "idle" && (
            <div className="task-banner">
              <Loader2 size={16} className={status.app.task?.status === "failed" ? "" : "spin"} />
              <span>{status.app.task?.status}: {status.app.task?.message}</span>
            </div>
          )}
          <div className="actions">
            <ActionButton busy={busy === "start"} disabled={!ready || actionBusy} onClick={() => act("start", "/api/comfy/start")} icon={<Play size={18} />} label="Start GPU session" />
            <ActionButton busy={busy === "scale"} disabled={actionBusy} onClick={() => act("scale", "/api/comfy/scale-down")} icon={<Square size={18} />} label="Scale down now" />
            <ActionButton busy={busy === "deploy"} disabled={!ready || actionBusy} onClick={() => act("deploy", "/api/image/deploy")} icon={<Rocket size={18} />} label="Deploy latest image" />
          </div>
          <div className="link-row">
            <a className={!status.endpoints.comfyui ? "disabled" : ""} href={status.endpoints.comfyui || "#"} target="_blank" rel="noreferrer">
              Open ComfyUI <ExternalLink size={15} />
            </a>
            <a className={!status.endpoints.jupyter ? "disabled" : ""} href={status.endpoints.jupyter || "#"} target="_blank" rel="noreferrer">
              Open Jupyter <ExternalLink size={15} />
            </a>
          </div>
        </Panel>

        <Panel className="span-5" title="Build Progress" icon={<Gauge size={18} />}>
          <div className="progress-head">
            <span>{status.build.status}{status.build.conclusion ? ` / ${status.build.conclusion}` : ""}</span>
            <strong>{Math.round(status.build.progress)}%</strong>
          </div>
          <div className="progress-track">
            <motion.div className="progress-fill" animate={{ width: `${status.build.progress}%` }} />
          </div>
          <button className="primary wide" disabled={!ready || actionBusy} onClick={() => act("bake", "/api/image/bake")}>
            {busy === "bake" ? <Loader2 className="spin" size={18} /> : <Layers size={18} />} Bake current ComfyUI changes
          </button>
          {status.build.url && <a className="build-link" href={status.build.url} target="_blank" rel="noreferrer">View GitHub run <ChevronRight size={15} /></a>}
        </Panel>

        <Panel className="span-4" title="Runtime Nodes" icon={<Layers size={18} />}>
          <Metric label="Baked" value={status.nodes.baked.length} />
          <Metric label="Pending" value={status.nodes.pending.length} />
          <Metric label="Visible" value={activeNodes.length} />
        </Panel>

        <Panel className="span-8" title="Node Actions" icon={<Check size={18} />}>
          <div className="actions">
            <ActionButton busy={busy === "wd14"} disabled={!ready || actionBusy} onClick={() => act("wd14", "/api/nodes/install-wd14")} icon={<Zap size={18} />} label="Install WD14 Tagger correctly" />
            <ActionButton busy={busy === "bake"} disabled={!ready || actionBusy} onClick={() => act("bake", "/api/image/bake", { deploy: false })} icon={<Box size={18} />} label="Bake for next deploy" />
          </div>
          <div className="node-list">
            {activeNodes.slice(0, 38).map((node) => <span key={node}>{node}</span>)}
            {activeNodes.length === 0 && <em>No nodes found yet.</em>}
          </div>
        </Panel>

        <Panel className="span-12" title="Control Activity" icon={<Activity size={18} />}>
          <div className="feed">
            {status.events.slice(-12).reverse().map((event, index) => (
              <motion.div key={`${event}-${index}`} initial={{ opacity: 0, x: -8 }} animate={{ opacity: 1, x: 0 }}>
                {event}
              </motion.div>
            ))}
          </div>
        </Panel>
      </section>
    </main>
  );
}

function CommandVisual({ live, deployed }: { live: boolean; deployed: boolean }) {
  const label = live ? "GPU Live" : deployed ? "Ready" : "Stopped";
  return (
    <motion.div className="command-visual" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.12, duration: 0.6 }}>
      <div className="visual-top">
        <span>{label}</span>
        <Flame size={22} />
      </div>
      <div className="signal-grid">
        {Array.from({ length: 24 }).map((_, index) => (
          <motion.i
            key={index}
            animate={{ opacity: live ? [0.35, 1, 0.45] : [0.25, 0.55, 0.25], scaleY: live ? [0.45, 1, 0.65] : [0.3, 0.55, 0.35] }}
            transition={{ duration: 1.3 + (index % 5) * 0.14, repeat: Infinity, delay: index * 0.025 }}
          />
        ))}
      </div>
      <div className="visual-bottom">
        <span>image sync</span>
        <strong>{live ? "active" : deployed ? "standby" : "offline"}</strong>
      </div>
    </motion.div>
  );
}

function Panel({ title, icon, className, children }: { title: string; icon: React.ReactNode; className?: string; children: React.ReactNode }) {
  return (
    <motion.section className={`panel ${className ?? ""}`} initial={{ opacity: 0, y: 14 }} animate={{ opacity: 1, y: 0 }} whileHover={{ y: -2 }}>
      <div className="panel-title">{icon}<span>{title}</span></div>
      {children}
    </motion.section>
  );
}

function StatusPill({ icon, label, ok }: { icon: React.ReactNode; label: string; ok: boolean }) {
  return <div className={`pill ${ok ? "ok" : "warn"}`}>{icon}<span>{label}</span><b>{ok ? "Ready" : "Needs setup"}</b></div>;
}

function Metric({ label, value }: { label: string; value: number }) {
  return <div className="metric"><span>{label}</span><strong>{value}</strong></div>;
}

function ActionButton({ busy, disabled, onClick, icon, label }: { busy: boolean; disabled: boolean; onClick: () => void; icon: React.ReactNode; label: string }) {
  return (
    <button className="primary" disabled={disabled} onClick={onClick}>
      {busy ? <Loader2 size={18} className="spin" /> : icon}
      {label}
    </button>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
