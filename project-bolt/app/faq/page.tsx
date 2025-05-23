import { FaqAccordion } from '@/components/faq/FaqAccordion';

export const metadata = {
  title: 'Întrebări Frecvente | TerapieAcasa.ro',
  description: 'Găsește răspunsuri la întrebările frecvente despre TerapieAcasa.ro',
};

export default function FaqPage() {
  return (
    <div className="container max-w-7xl mx-auto my-12 px-4 md:my-20">
      <div className="text-center mb-10">
        <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">
          Întrebări Frecvente
        </h1>
        <p className="mt-4 text-lg text-muted-foreground max-w-2xl mx-auto">
          Găsește răspunsuri la cele mai comune întrebări despre platforma noastră și serviciile de terapie
        </p>
      </div>
      
      <FaqAccordion />
    </div>
  );
}