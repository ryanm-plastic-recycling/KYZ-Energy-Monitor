import { Route, Routes } from 'react-router-dom'
import { DashboardPage } from './DashboardPage'
import { KioskPage } from './KioskPage'

export function App() {
  return (
    <Routes>
      <Route path="/" element={<DashboardPage />} />
      <Route path="/kiosk" element={<KioskPage />} />
    </Routes>
  )
}
