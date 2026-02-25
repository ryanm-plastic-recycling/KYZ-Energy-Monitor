const priEnv = import.meta.env.VITE_PRI_LOGO_URL
const innovEnv = import.meta.env.VITE_INNOVATION_LOGO_URL

export const PRI_LOGO_SRC =
  priEnv && priEnv.length > 0
    ? priEnv
    : '/pri-logo-vector.png'

export const INNOV_LOGO_SRC =
  innovEnv && innovEnv.length > 0
    ? innovEnv
    : '/Innovation%20Triangle%20-%20avatar.png'
