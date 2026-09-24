// Browser entry point. Vite's index.html loads this compiled module
// directly (`<script type="module" src="/src/web/Index.res.mjs">`) — no
// hand-written JS shim.

switch ReactDOM.querySelector("#root") {
| Some(root) => ReactDOM.Client.createRoot(root)->ReactDOM.Client.Root.render(<App />)
| None => ()
}
