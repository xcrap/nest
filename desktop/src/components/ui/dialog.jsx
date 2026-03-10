import * as DialogPrimitive from "@radix-ui/react-dialog";
import { X } from "lucide-react";

import { cn } from "../../lib/utils";

export const Dialog = DialogPrimitive.Root;
export const DialogTrigger = DialogPrimitive.Trigger;
export const DialogPortal = DialogPrimitive.Portal;
export const DialogClose = DialogPrimitive.Close;

export function DialogOverlay({ className, ...props }) {
  return <DialogPrimitive.Overlay className={cn("fixed inset-0 z-50 bg-slate-950/40 backdrop-blur-sm", className)} {...props} />;
}

export function DialogContent({ className, children, ...props }) {
  return (
    <DialogPortal>
      <DialogOverlay />
      <DialogPrimitive.Content
        className={cn(
          "fixed left-1/2 top-1/2 z-50 grid w-[min(92vw,720px)] -translate-x-1/2 -translate-y-1/2 gap-4 rounded-3xl border border-white/80 bg-white p-6 shadow-[0_30px_120px_rgba(15,23,42,0.22)]",
          className
        )}
        {...props}
      >
        {children}
        <DialogPrimitive.Close className="absolute right-4 top-4 rounded-lg p-2 text-slate-400 transition hover:bg-slate-100 hover:text-slate-900">
          <X className="h-4 w-4" />
          <span className="sr-only">Close</span>
        </DialogPrimitive.Close>
      </DialogPrimitive.Content>
    </DialogPortal>
  );
}

export function DialogHeader({ className, ...props }) {
  return <div className={cn("flex flex-col gap-1 text-left", className)} {...props} />;
}

export function DialogFooter({ className, ...props }) {
  return <div className={cn("flex flex-col-reverse gap-3 sm:flex-row sm:justify-end", className)} {...props} />;
}

export function DialogTitle({ className, ...props }) {
  return <DialogPrimitive.Title className={cn("text-xl font-semibold text-slate-950", className)} {...props} />;
}

export function DialogDescription({ className, ...props }) {
  return <DialogPrimitive.Description className={cn("text-sm text-slate-500", className)} {...props} />;
}
