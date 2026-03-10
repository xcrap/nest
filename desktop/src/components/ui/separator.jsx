import { cn } from "../../lib/utils";

export function Separator({ className, orientation = "horizontal", ...props }) {
  return (
    <div
      aria-hidden="true"
      className={cn(orientation === "horizontal" ? "h-px w-full" : "h-full w-px", "bg-slate-200", className)}
      {...props}
    />
  );
}
