// Vite's own dev/prod flag, per rewind's README "Dev Only" section. Bound
// here so App.res can pass it straight to Rewind.use(~enabled=...) without
// recording history (or mounting the panel) in a production build.
@val external viteDev: bool = "import.meta.env.DEV"
