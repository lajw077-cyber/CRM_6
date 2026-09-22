"use client";

import { useEffect, useState } from "react";

interface ConnectedInfo {
  connected: boolean;
  number?: string | null;
  pictureUrl?: string | null;
}

interface ConnectedWhatsAppInfoProps {
  /** Translated heading for this block, e.g. "Connected WhatsApp". */
  label: string;
}

/**
 * Shows which WhatsApp API number (and its account profile picture) is
 * connected to the caller's account. Mounted in the contact Profile
 * views so an agent can tell which connected WhatsApp account owns the
 * conversation — it is NEVER the customer's number or DP.
 *
 * Renders nothing while loading, when the account has no connected
 * number, or on any API failure, so existing profile layouts are
 * unaffected if the WhatsApp connection is missing or unreachable.
 */
export function ConnectedWhatsAppInfo({ label }: ConnectedWhatsAppInfoProps) {
  const [info, setInfo] = useState<ConnectedInfo | null>(null);

  useEffect(() => {
    let active = true;
    fetch("/api/whatsapp/connected/info")
      .then((res) => (res.ok ? res.json() : null))
      .then((data: ConnectedInfo | null) => {
        if (active && data?.connected && data.number) setInfo(data);
      })
      .catch(() => {
        // No connected number is a normal state — fail silently.
      });
    return () => {
      active = false;
    };
  }, []);

  if (!info) return null;

  return (
    <div className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm text-muted-foreground">
      <span className="flex h-7 w-7 shrink-0 items-center justify-center overflow-hidden rounded-full bg-muted">
        {info.pictureUrl ? (
          <img
            src={info.pictureUrl}
            alt=""
            className="h-7 w-7 rounded-full object-cover"
          />
        ) : (
          <span className="text-[10px] font-semibold text-foreground">WA</span>
        )}
      </span>
      <span className="flex min-w-0 flex-col leading-tight">
        <span className="text-[10px] uppercase tracking-wider text-muted-foreground">
          {label}
        </span>
        <span className="truncate font-medium text-foreground">
          {info.number}
        </span>
      </span>
    </div>
  );
}