import { Heart, Home, Video, Clock, Shield, Users } from 'lucide-react';

const features = [
  {
    icon: <Heart className="h-8 w-8 text-chart-1" />,
    title: 'Terapie personalizată',
    description: 'Găsești terapeutul potrivit stilului și nevoilor tale personale.',
  },
  {
    icon: <Home className="h-8 w-8 text-chart-2" />,
    title: 'Confort total',
    description: 'Participi la ședințe din confortul casei tale, fără deplasări stresante.',
  },
  {
    icon: <Video className="h-8 w-8 text-chart-3" />,
    title: 'Sesiuni online',
    description: 'Conectare video de înaltă calitate pentru o experiență apropiată celei din cabinet.',
  },
  {
    icon: <Clock className="h-8 w-8 text-chart-4" />,
    title: 'Program flexibil',
    description: 'Programează ședințe când îți este convenabil, inclusiv în afara orelor standard.',
  },
  {
    icon: <Shield className="h-8 w-8 text-chart-5" />,
    title: 'Confidențialitate',
    description: 'Toate discuțiile și datele tale sunt protejate cu cele mai înalte standarde de securitate.',
  },
  {
    icon: <Users className="h-8 w-8 text-chart-1" />,
    title: 'Terapeuți verificați',
    description: 'Toți terapeuții sunt verificați și au certificările profesionale necesare.',
  },
];

export function FeaturesSection() {
  return (
    <section className="py-16 md:py-24 bg-background">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="text-center mb-16">
          <h2 className="text-3xl font-bold tracking-tight sm:text-4xl">
            De ce să alegi <span className="text-primary">TerapieAcasa.ro</span>
          </h2>
          <p className="mt-4 text-xl text-muted-foreground max-w-2xl mx-auto">
            Platforma noastră oferă o experiență completă, sigură și convenabilă pentru terapie.
          </p>
        </div>
        
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-8">
          {features.map((feature, index) => (
            <div 
              key={index} 
              className="relative p-6 bg-card rounded-xl shadow-sm border border-border hover:shadow-md hover:border-primary/20 transition-all duration-300"
            >
              <div className="absolute top-6 right-6 p-3 rounded-full bg-primary/5">
                {feature.icon}
              </div>
              <h3 className="text-xl font-semibold mt-8">{feature.title}</h3>
              <p className="mt-2 text-muted-foreground">{feature.description}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}