// An omp extension that tells Lhûn which model omp runs, so the session's pill shows that model's mark
// (Lhun/ProgramIcon.swift). Inside tmux it keeps the pane option @lhun-model at the model
// as "provider/id" and clears it when omp exits; outside tmux it does nothing. omp loads extensions from
// ~/.omp/agent/extensions, and a profile only from its own. From the checkout root:
//   ln -s "$PWD/tools/omp/lhun-model.ts" ~/.omp/agent/extensions/lhun-model.ts
//   ln -s "$PWD/tools/omp/lhun-model.ts" ~/.omp/profiles/<profile>/agent/extensions/lhun-model.ts
import { spawnSync } from "node:child_process";

interface Model {
	provider: string;
	id: string;
}

interface Widget {
	render(width: number): readonly string[];
	invalidate(): void;
}

interface ExtensionContext {
	readonly hasUI: boolean;
	/** The session's model now: a getter, so a context kept from one event reads later switches too. */
	readonly model: Model | undefined;
	ui: { setWidget(key: string, content: () => Widget, options: { placement: "belowEditor" }): void };
}

interface ExtensionApi {
	on(event: string, handler: (event: unknown, ctx: ExtensionContext) => void): void;
}

const nothing: readonly string[] = [];

export default function lhunModel(pi: ExtensionApi): void {
	const pane = process.env.TMUX_PANE;
	if (!pane) return;
	let context: ExtensionContext | undefined;
	let told = "";

	// Run in order and only on a change, so tmux always ends on the model omp runs now.
	const tell = (model: string) => {
		if (model === told) return;
		told = model;
		const change = model ? ["@lhun-model", model] : ["-u", "@lhun-model"];
		spawnSync("tmux", ["set-option", "-p", "-t", pane, ...change], { stdio: "ignore", timeout: 1000 });
	};
	const check = () => {
		const model = context?.model;
		tell(model ? `${model.provider}/${model.id}` : "");
	};
	// An empty widget under the editor: the screen redraws it whenever anything changes, a /model or
	// /switch that rewrites the status line included, so a new model reaches tmux without polling.
	const watcher: Widget = {
		render: () => {
			check();
			return nothing;
		},
		invalidate: () => {},
	};

	// Subagents run without a UI and on models of their own; only the session in the pane counts.
	const start = (_event: unknown, ctx: ExtensionContext) => {
		if (!ctx.hasUI) return;
		context = ctx;
		ctx.ui.setWidget("lhun-model", () => watcher, { placement: "belowEditor" });
		check();
	};
	pi.on("session_start", start);
	pi.on("session_switch", start);
	for (const event of ["agent_start", "turn_start"]) {
		pi.on(event, (_event, ctx) => {
			if (!ctx.hasUI) return;
			context = ctx;
			check();
		});
	}
	// A final redraw during shutdown must not publish the model again. Headless child sessions never
	// own the pane option and must not clear the visible session's model.
	pi.on("session_shutdown", (_event, ctx) => {
		if (!ctx.hasUI) return;
		context = undefined;
		tell("");
	});
}
