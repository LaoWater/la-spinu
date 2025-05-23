import { ClientPreferenceForm } from '@/components/incepe/ClientPreferenceForm';

export const metadata = {
  title: 'Începe | TerapieAcasa.ro',
  description: 'Completează formularul pentru a găsi terapeutul potrivit pentru tine',
};

export default function IncepePage() {
  return (
    <div className="container max-w-7xl mx-auto my-12 px-4 md:my-20">
      <div className="text-center mb-10">
        <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">
          Începe călătoria ta către starea de bine
        </h1>
        <p className="mt-4 text-lg text-muted-foreground max-w-2xl mx-auto">
          Completează câteva detalii pentru a găsi terapeutul potrivit pentru tine.
          Procesul este simplu și te ajută să te conectezi cu un terapeut compatibil nevoilor tale.
        </p>
      </div>
      
      <ClientPreferenceForm />
    </div>
  );
}