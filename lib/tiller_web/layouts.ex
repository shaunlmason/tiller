defmodule TillerWeb.Layouts do
  @moduledoc "Root layout: one page, inline styles, prebuilt LiveView client."
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>tiller lab</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body { margin: 0; background: #14161a; color: #d7dae0; font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
          header { display: flex; gap: 12px; align-items: center; padding: 10px 16px; border-bottom: 1px solid #2a2e35; }
          header h1 { font-size: 14px; margin: 0 12px 0 0; font-weight: 600; letter-spacing: .04em; }
          button { background: #262a31; color: #e6e8ec; border: 1px solid #3a3f48; border-radius: 4px; padding: 5px 10px; font: inherit; cursor: pointer; }
          button:hover { background: #30353d; }
          button[disabled] { opacity: .45; cursor: default; }
          main { display: grid; grid-template-columns: minmax(280px, 1fr) minmax(320px, 1.2fr) minmax(320px, 1.2fr); gap: 1px; background: #2a2e35; height: calc(100vh - 46px); }
          section { background: #14161a; overflow: auto; padding: 12px 14px; }
          section h2 { font-size: 11px; text-transform: uppercase; letter-spacing: .08em; color: #8b93a1; margin: 0 0 10px; }
          .row { display: grid; grid-template-columns: 34px 1fr; gap: 8px; padding: 6px 8px; border-radius: 4px; cursor: pointer; border: 1px solid transparent; }
          .row:hover { background: #1c1f25; }
          .row.selected { border-color: #4f8cff; background: #182236; }
          .row .t { color: #8b93a1; }
          .row .a { white-space: pre-wrap; word-break: break-word; }
          .ok { color: #7bd88f; } .err { color: #ff7b72; } .halt { color: #c9a6ff; } .dim { color: #6b7280; }
          .sub { margin-left: 14px; border-left: 2px solid #2a2e35; padding-left: 8px; }
          .card { border: 1px solid #2a2e35; border-radius: 6px; padding: 10px 12px; margin-bottom: 10px; }
          .card h3 { margin: 0 0 6px; font-size: 12px; font-weight: 600; display: flex; justify-content: space-between; gap: 8px; }
          .card pre { margin: 4px 0 0; white-space: pre-wrap; word-break: break-word; }
          .bar { height: 6px; background: #262a31; border-radius: 3px; overflow: hidden; margin: 6px 0; }
          .bar > i { display: block; height: 100%; background: #4f8cff; transition: width .15s; }
          .bar.done > i { background: #7bd88f; }
          .bar.diverged > i { background: #ffb454; }
          .same { opacity: .55; }
          .diff { border-color: #ffb454; }
          .tag { font-size: 11px; color: #8b93a1; }
          .why { margin: 6px 0 0; padding-left: 8px; border-left: 2px solid #3a3f48; color: #9aa3b2; white-space: pre-wrap; word-break: break-word; }
          table.grid { border-collapse: separate; border-spacing: 2px; margin-bottom: 12px; }
          table.grid th { font-weight: 500; color: #8b93a1; font-size: 11px; padding: 0 2px 4px; }
          table.grid th.selected { color: #4f8cff; }
          table.grid td.bid { padding-right: 8px; white-space: nowrap; cursor: pointer; }
          table.grid td.bid:hover { color: #fff; }
          table.grid tr.picked td.bid { color: #4f8cff; }
          table.grid tr.smallest td.bid { color: #ffb454; }
          table.grid td.cell { width: 22px; height: 18px; border-radius: 3px; cursor: pointer; background: #1c1f25; }
          table.grid td.cell.same { background: #2f6b3f; }
          table.grid td.cell.diff { background: #ffb454; }
          table.grid td.cell.extra { background: #7c5cff; }
          table.grid td.cell.missing { background: #1c1f25; }
          table.grid td.cell:hover { outline: 1px solid #d7dae0; }
          table.grid td.verdict { padding-left: 8px; }
          table.grid { width: 100%; }
          p.band { margin: 0 0 10px; font-size: 12px; color: #a8b0bd; }
          p.band strong { color: #ffb454; }
          table.grid tr.control td.bid { color: #6b7280; }
          table.grid tr.in-band td.bid { color: #a8b0bd; }
          table.grid tr.in-band td.verdict { opacity: .6; }
        </style>
      </head>
      <body>
        {@inner_content}
        <script src="/vendor/phoenix/phoenix.min.js">
        </script>
        <script src="/vendor/live_view/phoenix_live_view.min.js">
        </script>
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
