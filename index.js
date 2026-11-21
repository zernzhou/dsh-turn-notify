/**
 * Host half of dsh-turn-notify.
 *
 * `session/event` carries each batch of recorded session events. The plugin
 * times a turn from its `turn/start` to its `turn/end`, learns the session
 * title when one is recorded, and hands a finished line of copy to
 * `notify-window.ps1`, which draws the always-on-top card.
 *
 * A watermark keeps replayed history from firing a card at load.
 *
 * No session data is read or written. Side effects are one spawned PowerShell
 * process and a diagnostic log under the OS temp directory.
 */
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, statSync, truncateSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/** Cordis plugin identity. */
export const name = "turn-notify";

/** No services are required; the plugin only listens to events. */
export const inject = [];

/** Every batch of recorded session events arrives on this name. */
const SESSION_EVENT = "session/event";

/** Session event types this plugin cares about. */
const TURN_START = "turn/start";
const TURN_END = "turn/end";
const SESSION_TITLE = "session/title";

/** Minimum gap between two cards. */
const MIN_GAP_MS = 300;

/** Keep the diagnostic log bounded. */
const MAX_LOG_BYTES = 256 * 1024;

/**
 * Format a duration for the card headline.
 * @param ms - elapsed milliseconds.
 * @returns a short human phrase, e.g. `47 秒`, `3 分 12 秒`, `1 小时 05 分`.
 */
function formatDuration(ms) {
	const totalSeconds = Math.max(1, Math.round(ms / 1000));
	if (totalSeconds < 60) return `${totalSeconds} 秒`;
	const minutes = Math.floor(totalSeconds / 60);
	if (minutes < 60) return `${minutes} 分 ${String(totalSeconds % 60).padStart(2, "0")} 秒`;
	const hours = Math.floor(minutes / 60);
	return `${hours} 小时 ${String(minutes % 60).padStart(2, "0")} 分`;
}

/**
 * Register the listener.
 * @param ctx - Cordis context owning listener lifetime.
 * @param config - optional `title` / `body` overrides, and `verbose: true` for batch diagnostics.
 */
export function apply(ctx, config = {}) {
	const titleOverride = typeof config.title === "string" && config.title.length > 0 ? config.title : "";
	const bodyOverride = typeof config.body === "string" && config.body.length > 0 ? config.body : "";
	const verbose = config.verbose === true;

	const stateDir = join(tmpdir(), "dsh-turn-notify");
	const logFile = join(stateDir, "events.log");
	try {
		mkdirSync(stateDir, { recursive: true });
		const size = statSync(logFile).size;
		if (size > MAX_LOG_BYTES) truncateSync(logFile, 0);
	} catch {
		/* a missing log must never break the plugin */
	}

	const log = (line) => {
		try {
			appendFileSync(logFile, `${new Date().toISOString()} ${line}\n`);
		} catch {
			/* ignore */
		}
	};

	if (process.platform !== "win32") {
		log(`disabled: platform ${process.platform} has no card path`);
		return;
	}

	const script = fileURLToPath(new URL("./notify-window.ps1", import.meta.url));
	const stateFile = join(stateDir, "card.json");
	const encode = (value) => Buffer.from(value, "utf8").toString("base64");
	let lastFiredAt = 0;
	/** Highest session seq already accounted for; null until the first batch. */
	let watermark = null;
	/** When the current turn started, by this process's clock. */
	let turnStartedAt = null;
	/** Latest recorded session title, without the trailing tool marker. */
	let sessionTitle = "";

	const fire = (payload) => {
		const now = Date.now();
		if (now - lastFiredAt < MIN_GAP_MS) {
			log(`skipped duplicate within ${MIN_GAP_MS}ms`);
			return;
		}
		lastFiredAt = now;
		const title = titleOverride || payload.title;
		const body = bodyOverride || payload.body;

		// One process per completion: notify-window.ps1 claims the lowest free
		// of three vertical slots, so cards stack instead of replacing each other.
		const child = spawn("powershell.exe", [
			"-NoProfile",
			"-STA",
			"-ExecutionPolicy", "Bypass",
			"-File", script,
			"-B64Title", encode(title),
			"-B64Body", encode(body),
		], { stdio: "ignore", windowsHide: true, detached: true });
		child.on("error", (error) => log(`spawn failed: ${error.message}`));
		child.unref();
		log(`card shown: ${title} | ${body}`);
	};

	/** Flatten the batch into {type, seq, data} records. */
	const collect = (payload) => {
		const found = [];
		const visit = (value, depth) => {
			if (depth > 3 || value === null || typeof value !== "object") return;
			if (Array.isArray(value)) {
				for (const item of value) {
					if (item === null || typeof item !== "object") continue;
					if (typeof item.type !== "string") continue;
					found.push({
						type: item.type,
						seq: typeof item.seq === "number" ? item.seq : undefined,
						data: item.data,
					});
				}
				return;
			}
			for (const key of ["eventsSnapshot", "events", "log", "batchPublication"]) {
				if (key in value) visit(value[key], depth + 1);
			}
		};
		visit(payload, 0);
		return found;
	};

	const onSessionEvent = (payload) => {
		const events = collect(payload);
		if (events.length === 0) return;

		// Session title is global to the session and cheap to keep current.
		for (const event of events) {
			if (event.type !== SESSION_TITLE) continue;
			const title = event.data?.title;
			if (typeof title === "string" && title.trim().length > 0) sessionTitle = title.trim();
		}

		let maxSeq;
		for (const event of events) {
			if (event.seq !== undefined && (maxSeq === undefined || event.seq > maxSeq)) maxSeq = event.seq;
		}

		// First observed batch is history: establish the watermark, never fire.
		if (watermark === null) {
			watermark = maxSeq ?? 0;
			turnStartedAt = null;
			if (verbose) log(`watermark established at ${watermark} (${events.length} events)`);
			return;
		}

		const fresh = events.filter((event) => event.seq === undefined || event.seq > watermark);
		if (maxSeq !== undefined && maxSeq > watermark) watermark = maxSeq;
		if (fresh.length === 0) return;

		for (const event of fresh) {
			if (event.type === TURN_START) {
				turnStartedAt = Date.now();
				continue;
			}
			if (event.type !== TURN_END) continue;

			const elapsed = turnStartedAt === null ? undefined : Date.now() - turnStartedAt;
			turnStartedAt = null;
			const title = elapsed === undefined ? "任务完成" : `任务完成 · 用时 ${formatDuration(elapsed)}`;
			const body = sessionTitle.length > 0
				? `${sessionTitle} 已经跑完了。点击卡片关闭。`
				: "这一轮已经跑完了。点击卡片关闭。";
			fire({ title, body });
		}
	};

	ctx.on(SESSION_EVENT, onSessionEvent);
	ctx.on(SESSION_EVENT, onSessionEvent, { global: true });

	log(`turn-notify loaded; waiting for a fresh ${TURN_END}`);
}
