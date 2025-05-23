import { SearchIcon, CalendarIcon, MessageSquareIcon } from 'lucide-react';

const steps = [
  {
    icon: <SearchIcon className="h-10 w-10 text-primary" />,
    title: 'Alegeti un terapeut potrivit',
    description: 'Completați formularul de preferințe și găsiți terapeutul care se potrivește nevoilor dvs.',
  },
  {
    icon: <CalendarIcon className="h-10 w-10 text-primary" />,
    title: 'Programați o ședință',
    description: 'Selectați data și ora convenabilă și confirmați programarea cu terapeutul ales.',
  },
  {
    icon: <MessageSquareIcon className="h-10 w-10 text-primary" />,
    title: 'Participați la ședință',
    description: 'Conectați-vă pentru ședința online sau așteptați terapeutul la domiciliu la ora stabilită.',
  },
];

export function StepsSection() {
  return (
    <section className="py-16 md:py-24 bg-muted">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="text-center mb-16">
          <h2 className="text-3xl font-bold tracking-tight sm:text-4xl">
            Cum funcționează
          </h2>
          <p className="mt-4 text-xl text-muted-foreground max-w-2xl mx-auto">
            Procesul simplu de conectare cu terapeuți profesioniști
          </p>
        </div>
        
        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
          {steps.map((step, index) => (
            <div key={index} className="text-center">
              <div className="flex justify-center items-center h-24 w-24 rounded-full bg-primary/10 mx-auto">
                {step.icon}
              </div>
              
              <div className="relative">
                {index < steps.length - 1 && (
                  <div className="hidden md:block absolute top-12 left-full w-full h-0.5 bg-primary/30">
                    <div className="absolute -right-3 -top-1.5 h-4 w-4 rounded-full bg-primary"></div>
                  </div>
                )}
              </div>
              
              <h3 className="mt-6 text-xl font-semibold">{step.title}</h3>
              <p className="mt-2 text-muted-foreground">{step.description}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}