export type AppSurface = 'main' | 'hud' | 'agent-overlay'

export function resolveSurface(search: string): AppSurface {
  const surface = new URLSearchParams(search).get('surface')
  return surface === 'hud' || surface === 'agent-overlay' ? surface : 'main'
}
