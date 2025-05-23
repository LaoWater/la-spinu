import { TherapistRegistrationInfo } from '@/components/terapeuti/TherapistRegistrationInfo';

export const metadata = {
  title: 'Pentru Terapeuți | TerapieAcasa.ro',
  description: 'Informații pentru terapeuți care doresc să se alăture platformei TerapieAcasa.ro',
};

export default function TerapeutiPage() {
  return (
    <div className="container max-w-7xl mx-auto my-12 px-4 md:my-20">
      <div className="text-center mb-10">
        <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">
          Pentru Terapeuți
        </h1>
        <p className="mt-4 text-lg text-muted-foreground max-w-2xl mx-auto">
          Ești terapeut? Alătură-te platformei noastre pentru a oferi terapie online sau la domiciliul clienților.
        </p>
      </div>
      
      <TherapistRegistrationInfo />
    </div>
  );
}