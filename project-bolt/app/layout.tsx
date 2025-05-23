import './globals.css';
import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import { Navbar } from '@/components/layout/Navbar';
import { Footer } from '@/components/layout/Footer';
import { AuthProvider } from '@/contexts/AuthContext';

const inter = Inter({ subsets: ['latin'] });

export const metadata: Metadata = {
  title: 'TerapieAcasa.ro - Conectăm oamenii cu terapeuți profesioniști',
  description: 'Platformă online care conectează clienți cu terapeuți pentru ședințe de terapie la domiciliu sau online',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="ro">
      <body className={`${inter.className} min-h-screen flex flex-col`}>
        <AuthProvider>
          <Navbar />
          <main className="flex-grow pt-16">
            {children}
          </main>
          <Footer />
        </AuthProvider>
      </body>
    </html>
  );
}