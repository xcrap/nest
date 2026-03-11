import { FileText } from "lucide-react";

import { Card } from "../components/ui/card";
import { ScrollArea } from "../components/ui/scroll-area";

export function LogsScreen({ content }) {
  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <FileText className="h-4 w-4 text-zinc-400" />
        <h2 className="text-lg font-semibold text-zinc-900">Runtime logs</h2>
        <span className="text-sm text-zinc-400">FrankenPHP stdout / stderr</span>
      </div>

      <Card className="overflow-hidden">
        <ScrollArea className="h-[calc(100vh-200px)]">
          <pre className="min-h-[400px] whitespace-pre-wrap bg-zinc-950 px-5 py-4 font-mono text-[13px] leading-relaxed text-zinc-300">
            {content || "No logs recorded yet."}
          </pre>
        </ScrollArea>
      </Card>
    </div>
  );
}
