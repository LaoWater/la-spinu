import { Avatar, AvatarFallback, AvatarImage } from '@/components/ui/avatar';
import { Card, CardContent, CardFooter } from '@/components/ui/card';

const testimonials = [
  {
    quote: 'Terapia online prin TerapieAcasa.ro mi-a schimbat viața. Am putut să lucrez cu un terapeut excelent fără să părăsesc confortul locuinței mele.',
    author: 'Maria D.',
    location: 'București',
    avatar: 'https://images.pexels.com/photos/774909/pexels-photo-774909.jpeg?auto=compress&cs=tinysrgb&w=600',
  },
  {
    quote: 'După multe căutări, am găsit terapeutul potrivit prin această platformă. Procesul a fost simplu și am apreciat recenziile detaliate.',
    author: 'Andrei M.',
    location: 'Cluj-Napoca',
    avatar: 'https://images.pexels.com/photos/1222271/pexels-photo-1222271.jpeg?auto=compress&cs=tinysrgb&w=600',
  },
  {
    quote: 'Ca mamă ocupată, a fost imposibil să găsesc timp pentru terapie până am descoperit TerapieAcasa.ro. Acum pot programa ședințe după ce copiii adorm.',
    author: 'Elena R.',
    location: 'Timișoara',
    avatar: 'https://images.pexels.com/photos/1239291/pexels-photo-1239291.jpeg?auto=compress&cs=tinysrgb&w=600',
  },
];

export function TestimonialsSection() {
  return (
    <section className="py-16 md:py-24 bg-background">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="text-center mb-16">
          <h2 className="text-3xl font-bold tracking-tight sm:text-4xl">
            Ce spun clienții noștri
          </h2>
          <p className="mt-4 text-xl text-muted-foreground max-w-2xl mx-auto">
            Experiențe reale ale persoanelor care au folosit platforma noastră
          </p>
        </div>
        
        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
          {testimonials.map((testimonial, index) => (
            <Card key={index} className="bg-card border border-border hover:shadow-md transition-shadow duration-300">
              <CardContent className="pt-6">
                <div className="relative">
                  <span className="absolute -top-2 -left-2 text-5xl text-primary opacity-20">"</span>
                  <p className="relative text-lg italic text-card-foreground">
                    {testimonial.quote}
                  </p>
                </div>
              </CardContent>
              
              <CardFooter className="flex items-center gap-4 pt-4 pb-6">
                <Avatar>
                  <AvatarImage src={testimonial.avatar} alt={testimonial.author} />
                  <AvatarFallback>{testimonial.author.split(' ').map(n => n[0]).join('')}</AvatarFallback>
                </Avatar>
                
                <div>
                  <p className="font-semibold">{testimonial.author}</p>
                  <p className="text-sm text-muted-foreground">{testimonial.location}</p>
                </div>
              </CardFooter>
            </Card>
          ))}
        </div>
      </div>
    </section>
  );
}