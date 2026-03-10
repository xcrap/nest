import { cva } from "class-variance-authority";

import { cn } from "../../lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-xl text-sm font-medium transition-all duration-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-slate-900/10 disabled:pointer-events-none disabled:opacity-50",
  {
    variants: {
      variant: {
        default: "bg-slate-950 text-white shadow-[0_12px_30px_rgba(15,23,42,0.18)] hover:bg-slate-800",
        secondary: "bg-white text-slate-900 shadow-sm ring-1 ring-slate-200 hover:bg-slate-50",
        outline: "bg-transparent text-slate-700 ring-1 ring-slate-200 hover:bg-white/80",
        ghost: "bg-transparent text-slate-700 hover:bg-slate-100",
        destructive: "bg-rose-600 text-white shadow-[0_12px_30px_rgba(225,29,72,0.18)] hover:bg-rose-500"
      },
      size: {
        default: "h-10 px-4 py-2",
        sm: "h-8 rounded-lg px-3 text-xs",
        lg: "h-11 px-5 text-sm",
        icon: "h-10 w-10"
      }
    },
    defaultVariants: {
      variant: "default",
      size: "default"
    }
  }
);

function Button({ className, variant, size, asChild = false, ...props }) {
  const Component = asChild ? "span" : "button";
  return <Component className={cn(buttonVariants({ variant, size }), className)} {...props} />;
}

export { Button, buttonVariants };
