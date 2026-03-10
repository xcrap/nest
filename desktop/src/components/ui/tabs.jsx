import * as TabsPrimitive from "@radix-ui/react-tabs";

import { cn } from "../../lib/utils";

export const Tabs = TabsPrimitive.Root;

export function TabsList({ className, ...props }) {
  return (
    <TabsPrimitive.List
      className={cn("inline-flex h-auto flex-col gap-2 rounded-2xl bg-transparent p-0 text-slate-600", className)}
      {...props}
    />
  );
}

export function TabsTrigger({ className, ...props }) {
  return (
    <TabsPrimitive.Trigger
      className={cn(
        "inline-flex items-center justify-between rounded-2xl border border-transparent px-4 py-3 text-left text-sm font-medium transition data-[state=active]:border-white data-[state=active]:bg-white data-[state=active]:text-slate-950 data-[state=active]:shadow-sm hover:bg-white/70",
        className
      )}
      {...props}
    />
  );
}

export const TabsContent = TabsPrimitive.Content;
