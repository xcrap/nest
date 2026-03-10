import * as SwitchPrimitive from "@radix-ui/react-switch";

import { cn } from "../../lib/utils";

export function Switch({ className, ...props }) {
  return (
    <SwitchPrimitive.Root
      className={cn(
        "peer inline-flex h-6 w-11 shrink-0 cursor-pointer items-center rounded-full border border-transparent bg-slate-200 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-slate-900/10 data-[state=checked]:bg-slate-950 disabled:cursor-not-allowed disabled:opacity-50",
        className
      )}
      {...props}
    >
      <SwitchPrimitive.Thumb className="pointer-events-none block h-5 w-5 translate-x-0.5 rounded-full bg-white shadow-lg ring-0 transition-transform data-[state=checked]:translate-x-5" />
    </SwitchPrimitive.Root>
  );
}
