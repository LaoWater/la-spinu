import Link from 'next/link';

export function Footer() {
  const currentYear = new Date().getFullYear();
  
  return (
    <footer className="bg-muted mt-auto py-8">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
          <div>
            <h3 className="text-lg font-semibold mb-4">TerapieAcasa.ro</h3>
            <p className="text-muted-foreground">
              Conectăm oamenii cu terapeuți profesioniști pentru sesiuni online sau la domiciliu.
            </p>
          </div>
          
          <div>
            <h3 className="text-lg font-semibold mb-4">Linkuri Rapide</h3>
            <ul className="space-y-2">
              <li>
                <Link href="/" className="text-muted-foreground hover:text-foreground transition-colors">
                  Acasă
                </Link>
              </li>
              <li>
                <Link href="/terapeuti" className="text-muted-foreground hover:text-foreground transition-colors">
                  Pentru Terapeuți
                </Link>
              </li>
              <li>
                <Link href="/despre" className="text-muted-foreground hover:text-foreground transition-colors">
                  Despre Noi
                </Link>
              </li>
              <li>
                <Link href="/faq" className="text-muted-foreground hover:text-foreground transition-colors">
                  Întrebări Frecvente
                </Link>
              </li>
            </ul>
          </div>
          
          <div>
            <h3 className="text-lg font-semibold mb-4">Contact</h3>
            <p className="text-muted-foreground">
              Email: contact@terapieacasa.ro<br />
              Telefon: 0700 000 000
            </p>
            <div className="mt-4 flex space-x-4">
              <Link href="#" className="text-muted-foreground hover:text-foreground transition-colors">
                Facebook
              </Link>
              <Link href="#" className="text-muted-foreground hover:text-foreground transition-colors">
                Instagram
              </Link>
              <Link href="#" className="text-muted-foreground hover:text-foreground transition-colors">
                LinkedIn
              </Link>
            </div>
          </div>
        </div>
        
        <div className="mt-8 pt-8 border-t border-border">
          <p className="text-center text-muted-foreground">
            &copy; {currentYear} TerapieAcasa.ro. Toate drepturile rezervate.
          </p>
        </div>
      </div>
    </footer>
  );
}