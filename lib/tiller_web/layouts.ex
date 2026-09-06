defmodule TillerWeb.Layouts do
  @moduledoc "The one root layout: inline CSS, the two vendored scripts, the LiveSocket."
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>tiller butterfly lab</title>
        <style>
          :root { color-scheme: dark; --bg:#101216; --panel:#171a21; --line:#2a2f3a; --fg:#d7dbe3; --dim:#7d8594;
                  --ok:#4caf7d; --err:#e0605a; --replay:#5b8def; --halt:#8a8f9c; --sel:#f0c04a; --div:#ff7ad9; }
          * { box-sizing: border-box; }
          body { margin:0; background:var(--bg); color:var(--fg); font:13px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
          header { display:flex; gap:12px; align-items:center; padding:8px 14px; border-bottom:1px solid var(--line); }
          header h1 { font-size:14px; margin:0 12px 0 0; font-weight:600; }
          main { display:grid; grid-template-columns: 1.3fr 1fr 1.1fr; gap:0; height: calc(100vh - 42px); }
          section { padding:12px 14px; overflow:auto; border-right:1px solid var(--line); }
          section:last-child { border-right:0; }
          h2 { font-size:12px; text-transform:uppercase; letter-spacing:.08em; color:var(--dim); margin:0 0 10px; }
          button { background:var(--panel); color:var(--fg); border:1px solid var(--line); border-radius:4px; padding:4px 10px; cursor:pointer; font:inherit; }
          button:hover { border-color:var(--dim); }
          input[type=number] { width:4em; background:var(--panel); color:var(--fg); border:1px solid var(--line); border-radius:4px; padding:3px 6px; font:inherit; }
          .session { margin-bottom:12px; padding:8px; background:var(--panel); border:1px solid var(--line); border-radius:6px; }
          .session .name { display:flex; justify-content:space-between; gap:8px; margin-bottom:6px; }
          .session .meta { color:var(--dim); }
          .turns { display:flex; flex-wrap:wrap; gap:4px; }
          .turn { min-width:26px; height:22px; padding:0 6px; border-radius:4px; border:1px solid transparent; display:inline-flex; align-items:center; justify-content:center; cursor:pointer; font-size:11px; color:#0c0e12; }
          .turn.ok { background:var(--ok); } .turn.err { background:var(--err); } .turn.replay { background:var(--replay); } .turn.halt { background:var(--halt); }
          .turn.selected { outline:2px solid var(--sel); outline-offset:1px; }
          .turn.diverge { box-shadow:0 0 0 2px var(--div); }
          .running { color:var(--ok); } .halted { color:var(--dim); } .dead { color:var(--err); }
          .cluster { margin:0 0 10px 12px; padding:6px 8px; border-left:2px solid var(--line); }
          .cluster-head { display:flex; gap:10px; align-items:baseline; margin-bottom:4px; }
          .branch { display:grid; grid-template-columns: minmax(9em, 14em) minmax(8em, 1fr) 5em auto; gap:8px; align-items:center; padding:2px 0; border-top:1px solid var(--line); }
          .branch .bid { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
          .branch .bmut { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
          .branch .turns { flex-wrap:nowrap; }
          .branch .turn { min-width:18px; height:16px; padding:0 3px; font-size:10px; }
          pre { white-space:pre-wrap; word-break:break-word; background:var(--panel); border:1px solid var(--line); border-radius:6px; padding:8px; margin:6px 0 12px; }
          .kv { color:var(--dim); } .kv b { color:var(--fg); font-weight:500; }
          label.m { display:block; margin:3px 0; cursor:pointer; }
          table { width:100%; border-collapse:collapse; margin-top:10px; }
          td, th { text-align:left; padding:4px 6px; border-bottom:1px solid var(--line); vertical-align:top; }
          td { overflow-wrap:anywhere; }
          th { color:var(--dim); font-weight:500; white-space:nowrap; }
          .verdict.identical { color:var(--ok); } .verdict.diverged { color:var(--div); } .verdict.pending { color:var(--dim); } .verdict.error { color:var(--err); }
          .legend span { display:inline-block; width:10px; height:10px; border-radius:2px; margin:0 4px 0 10px; vertical-align:middle; }
        </style>
        <script src="/phoenix/phoenix.min.js"></script>
        <script src="/live_view/phoenix_live_view.min.js"></script>
      </head>
      <body>
        {@inner_content}
        <script>
          const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: csrf}});
          liveSocket.connect();
          window.liveSocket = liveSocket;
        </script>
      </body>
    </html>
    """
  end
end
