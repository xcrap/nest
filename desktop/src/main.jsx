import React from "react";
import ReactDOM from "react-dom/client";

import App from "./App";
import "./styles.css";

class RootErrorBoundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error) {
    return { error };
  }

  render() {
    if (!this.state.error) {
      return this.props.children;
    }

    return (
      <div className="flex min-h-screen items-center justify-center bg-zinc-50 p-8 text-zinc-950">
        <div className="max-w-xl rounded-3xl border border-red-200 bg-white p-8 shadow-[0_18px_50px_-40px_rgba(24,24,27,0.35)]">
          <p className="text-xs font-semibold uppercase tracking-[0.18em] text-red-600">Nest Error</p>
          <h1 className="mt-3 text-3xl font-semibold tracking-[-0.04em]">Nest hit a renderer error.</h1>
          <p className="mt-3 text-sm leading-6 text-zinc-500">
            The window stayed open, but the interface crashed. Reload the window and retry the last action.
          </p>
          <div className="mt-6 rounded-2xl border border-red-100 bg-red-50 px-4 py-3">
            <p className="text-[13px] font-medium text-red-700">{String(this.state.error?.message || this.state.error)}</p>
          </div>
          <button
            className="mt-6 inline-flex items-center rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800"
            onClick={() => window.location.reload()}
            type="button"
          >
            Reload window
          </button>
        </div>
      </div>
    );
  }
}

ReactDOM.createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <RootErrorBoundary>
      <App />
    </RootErrorBoundary>
  </React.StrictMode>
);
