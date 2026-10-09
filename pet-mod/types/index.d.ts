/** What Claude is doing in a chat, as the floating Mochi shows it */
export type Status = 'idle' | 'running' | 'needs-input' | 'ready' | 'blocked'

/** One line in a chat's log of things that finished or arrived */
export type PetEvent = {
  kind: 'turn' | 'helper' | 'task' | 'routine' | 'message'
  text: string
  /** One short line on what it was: a summary of Claude's answer, or why it stopped */
  detail?: string
  /** How long it took */
  seconds?: number
  /** When it happened, in milliseconds since 1970 */
  at: number
}

declare module 'claude-code' {
  interface PluginState {
    'pet-mod': {
      status: Status
      log: PetEvent[]
      /** What Claude wants your OK for, while the status is needs-input */
      waiting: string
    }
  }
}
