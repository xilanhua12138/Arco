import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../i18n/i18n'
import { SettingsSheet } from './SettingsSheet'

describe('SettingsSheet language preference', () => {
  it('switches the complete settings surface to Chinese and persists the choice', async () => {
    window.localStorage.setItem('arco.locale', 'en')
    const user = userEvent.setup()
    render(
      <I18nProvider>
        <SettingsSheet open initialPage="general" runtimes={[]} isDesktop onClose={vi.fn()} />
      </I18nProvider>,
    )

    await user.selectOptions(screen.getByRole('combobox', { name: 'App language' }), 'zh-CN')

    expect(screen.getByRole('dialog', { name: '通用' })).toBeVisible()
    expect(screen.getByRole('button', { name: '修改聆听快捷键' })).toBeVisible()
    expect(screen.getByRole('button', { name: '音频与说话人' })).toBeVisible()
    expect(window.localStorage.getItem('arco.locale')).toBe('zh-CN')
    expect(document.documentElement.lang).toBe('zh-CN')

    await user.click(screen.getByRole('button', { name: '数据与隐私' }))
    expect(screen.getByRole('dialog', { name: '数据与隐私' })).toBeVisible()
    expect(screen.queryByRole('combobox', { name: '界面语言' })).not.toBeInTheDocument()
    expect(screen.getByText('会议存储和 Agent 上下文是两项独立选择。Arco 会在每次提问前显示上下文边界。')).toBeVisible()
  })
})
