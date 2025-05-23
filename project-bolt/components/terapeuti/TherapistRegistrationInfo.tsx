import Link from 'next/link';
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { CheckCircle } from 'lucide-react';

const benefits = [
  'Conectare cu clienți potriviți nevoilor tale',
  'Program flexibil, definit de tine',
  'Platformă sigură pentru sesiuni online',
  'Proces de plată automatizat',
  'Recenzii și feedback pentru dezvoltare profesională',
  'Suport pentru dezvoltarea carierei tale',
];

export function TherapistRegistrationInfo() {
  return (
    <Card className="w-full max-w-3xl mx-auto">
      <CardHeader className="text-center">
        <CardTitle className="text-3xl font-bold">
          Alătură-te rețelei de terapeuți TerapieAcasa.ro
        </CardTitle>
        <CardDescription className="text-lg mt-2">
          Oferă serviciile tale de terapie online sau la domiciliul clienților, pe cea mai inovativă platformă din România
        </CardDescription>
      </CardHeader>
      
      <CardContent>
        <div className="space-y-8">
          <div>
            <h3 className="text-xl font-semibold mb-4">Beneficii pentru terapeuți</h3>
            <ul className="space-y-3">
              {benefits.map((benefit, index) => (
                <li key={index} className="flex items-start">
                  <CheckCircle className="h-5 w-5 text-primary mr-2 flex-shrink-0 mt-0.5" />
                  <span>{benefit}</span>
                </li>
              ))}
            </ul>
          </div>
          
          <div>
            <h3 className="text-xl font-semibold mb-4">Cum funcționează</h3>
            <ol className="space-y-3 list-decimal pl-5">
              <li>Înregistrează-te pe platformă ca terapeut</li>
              <li>Completează profilul tău profesional și adaugă certificările</li>
              <li>Setează disponibilitatea și preferințele pentru sesiuni</li>
              <li>Primește solicitări de la clienți potriviți experienței tale</li>
              <li>Oferă sesiuni de terapie de calitate și primește feedback</li>
            </ol>
          </div>
          
          <div className="bg-muted p-6 rounded-lg">
            <h3 className="text-xl font-semibold mb-2">În curând disponibil</h3>
            <p className="text-muted-foreground">
              Lucrăm la perfecționarea platformei pentru terapeuți. În curând vei putea să îți creezi un profil detaliat pentru a-ți oferi serviciile. Înregistrează-te acum pentru a primi notificare când procesul complet de înregistrare va fi disponibil.
            </p>
          </div>
        </div>
      </CardContent>
      
      <CardFooter className="flex flex-col md:flex-row gap-4 justify-center">
        <Link href="/autentificare">
          <Button size="lg" className="w-full md:w-auto">
            Înregistrează-te ca terapeut
          </Button>
        </Link>
        
        <Link href="/faq">
          <Button variant="outline" size="lg" className="w-full md:w-auto">
            Întrebări frecvente
          </Button>
        </Link>
      </CardFooter>
    </Card>
  );
}