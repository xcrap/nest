import { FileText, RefreshCw } from "lucide-react";

import { Button } from "../components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "../components/ui/card";
import { ScrollArea } from "../components/ui/scroll-area";

export function LogsScreen({ content, onRefresh }) {
  return (
    <Card className="overflow-hidden">
      <CardHeader className="border-b border-slate-200/80">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="space-y-1">
            <CardTitle className="flex items-center gap-2">
              <FileText className="h-5 w-5 text-slate-500" />
              Runtime logs
            </CardTitle>
            <CardDescription>Live stdout and stderr written by FrankenPHP.</CardDescription>
          </div>
          <Button variant="secondary" onClick={onRefresh}>
            <RefreshCw className="h-4 w-4" />
            Refresh
          </Button>
        </div>
      </CardHeader>
      <CardContent className="p-0">
        <ScrollArea className="h-[680px]">
          <pre className="m-0 min-h-[680px] whitespace-pre-wrap bg-slate-950 px-6 py-5 font-mono text-sm leading-6 text-slate-200">
            {content || "No logs recorded yet."}
          </pre>
        </ScrollArea>
      </CardContent>
    </Card>
  );
}
