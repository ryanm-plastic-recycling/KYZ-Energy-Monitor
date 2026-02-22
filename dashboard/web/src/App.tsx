import { Route, Routes } from 'react-router-dom'
import { DashboardPage } from './DashboardPage'
import { KioskPage } from './KioskPage'

export function App() {
  return (
    <Routes>
      <Route path="/kiosk" element={<KioskPage />} />
      <Route path="*" element={<DashboardPage />} />
    </Routes>
  )
}
