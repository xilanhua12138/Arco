import { useContext } from 'react'
import { I18nContext } from './context'

export const useI18n = () => useContext(I18nContext)
