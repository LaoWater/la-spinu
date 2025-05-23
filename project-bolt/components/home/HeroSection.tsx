import Link from 'next/link';
import { Button } from '@/components/ui/button';

export function HeroSection() {
  return (
    <section className="relative py-20 md:py-32 overflow-hidden bg-gradient-to-br from-background to-muted">
      <div className="absolute inset-0 bg-[url('https://images.pexels.com/photos/4101143/pexels-photo-4101143.jpeg?auto=compress&cs=tinysrgb&w=1260&h=750&dpr=2')] bg-cover bg-center opacity-10"></div>
      
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 relative">
        <div className="text-center lg:text-left">
          <h1 className="text-3xl sm:text-4xl md:text-5xl lg:text-6xl font-bold tracking-tight">
            <span className="block text-primary">Meriți să fii fericit.</span>
            <span className="block mt-2">Ce tip de terapie cauți?</span>
          </h1>
          
          <p className="mt-6 text-lg md:text-xl text-muted-foreground max-w-2xl mx-auto lg:mx-0">
            TerapieAcasa.ro conectează persoane ca tine cu terapeuți profesioniști pentru ședințe online sau la domiciliu, adaptate nevoilor tale.
          </p>
          
          <div className="mt-8 flex flex-col sm:flex-row gap-4 justify-center lg:justify-start">
            <Link href="/incepe">
              <Button size="lg" className="w-full sm:w-auto">
                Începe
              </Button>
            </Link>
            
            <Link href="/despre">
              <Button size="lg" variant="outline" className="w-full sm:w-auto">
                Află mai mult
              </Button>
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}