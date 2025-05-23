export const metadata = {
  title: 'Despre Noi | TerapieAcasa.ro',
  description: 'Află mai multe despre misiunea și echipa TerapieAcasa.ro',
};

export default function DesprePage() {
  return (
    <div className="container max-w-7xl mx-auto my-12 px-4 md:my-20">
      <div className="text-center mb-10">
        <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">
          Despre Noi
        </h1>
        <p className="mt-4 text-lg text-muted-foreground max-w-2xl mx-auto">
          Află mai multe despre misiunea noastră de a face terapia accesibilă tuturor
        </p>
      </div>
      
      <div className="max-w-3xl mx-auto prose prose-h3:text-xl prose-h3:font-semibold">
        <div className="mb-12">
          <h2 className="text-2xl font-bold mb-4">Misiunea Noastră</h2>
          <p>
            La TerapieAcasa.ro, misiunea noastră este să facem terapia mai accesibilă pentru toți. 
            Credem că fiecare persoană merită șansa de a trăi o viață echilibrată și fericită, 
            iar accesul la suport terapeutic de calitate este esențial în această călătorie.
          </p>
          <p>
            Platforma noastră conectează oameni cu terapeuți profesioniști pentru sesiuni online 
            sau la domiciliu, eliminând barierele tradiționale ale terapiei cum ar fi programul 
            rigid, locațiile inconveniente sau stigmatizarea socială.
          </p>
        </div>
        
        <div className="mb-12">
          <h2 className="text-2xl font-bold mb-4">Povestea Noastră</h2>
          <p>
            TerapieAcasa.ro a fost creată din dorința de a rezolva o problemă reală în societatea 
            românească: accesul limitat la servicii terapeutice de calitate. Fondatorii noștri, 
            inspirați de experiențele personale și din dorința de a aduce o schimbare pozitivă, 
            au dezvoltat această platformă pentru a elimina obstacolele din calea sănătății mintale.
          </p>
          <p>
            De la lansare, am crescut constant, adăugând noi terapeuți calificați și dezvoltând 
            funcționalități care să îmbunătățească experiența atât pentru clienți, cât și pentru terapeuți.
          </p>
        </div>
        
        <div className="mb-12">
          <h2 className="text-2xl font-bold mb-4">Valorile Noastre</h2>
          <div className="space-y-6">
            <div>
              <h3>Accesibilitate</h3>
              <p>
                Credem că serviciile terapeutice trebuie să fie accesibile tuturor, 
                indiferent de locație, program sau circumstanțe personale.
              </p>
            </div>
            <div>
              <h3>Calitate</h3>
              <p>
                Colaborăm doar cu terapeuți certificați, cu experiență și verificați, 
                asigurându-ne că clienții primesc cea mai bună îngrijire posibilă.
              </p>
            </div>
            <div>
              <h3>Confidențialitate</h3>
              <p>
                Protejăm cu strictețe confidențialitatea clienților și terapeuților noștri, 
                folosind tehnologii avansate de securitate pentru toate datele și comunicările.
              </p>
            </div>
            <div>
              <h3>Inovație</h3>
              <p>
                Continuăm să inovăm și să ne adaptăm pentru a oferi cele mai bune soluții 
                în domeniul terapiei online și la domiciliu.
              </p>
            </div>
          </div>
        </div>
        
        <div>
          <h2 className="text-2xl font-bold mb-4">Echipa Noastră</h2>
          <p>
            Suntem o echipă diversă de profesioniști din domeniul sănătății mintale, 
            tehnologiei și afacerilor, uniți de pasiunea pentru a crea o societate mai 
            sănătoasă și mai fericită. Cu experiență vastă în domeniile noastre, 
            lucrăm împreună pentru a oferi cea mai bună experiență utilizatorilor platformei.
          </p>
          <p>
            Credem în puterea terapiei și în potențialul fiecărei persoane de a trăi 
            o viață împlinită. Prin intermediul TerapieAcasa.ro, facem acest lucru posibil.
          </p>
        </div>
      </div>
    </div>
  );
}