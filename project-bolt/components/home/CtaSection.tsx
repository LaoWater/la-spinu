import Link from 'next/link';
import { Button } from '@/components/ui/button';

export function CtaSection() {
  return (
    <section className="py-16 md:py-24 bg-primary text-primary-foreground">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 text-center">
        <h2 className="text-3xl font-bold tracking-tight sm:text-4xl md:text-5xl">
          Gata să începi călătoria către o viață mai bună?
        </h2>
        
        <p className="mt-6 text-xl max-w-2xl mx-auto text-primary-foreground/80">
          Conectează-te cu un terapeut potrivit și fă primul pas către starea de bine pe care o meriți.
        </p>
        
        <div className="mt-10">
          <Link href="/incepe">
            <Button size="lg" variant="secondary" className="text-lg px-8 py-6">
              Începe acum
            </Button>
          </Link>
        </div>
      </div>
    </section>
  );
}