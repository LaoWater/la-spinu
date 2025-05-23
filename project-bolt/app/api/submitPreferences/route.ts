import { NextResponse } from 'next/server';

export async function POST(request: Request) {
  try {
    const data = await request.json();
    
    // Here we would typically save the data to the database
    // and potentially trigger the matching algorithm
    console.log('Preferences received:', data);
    
    // For now, we just acknowledge receipt
    return NextResponse.json({ 
      success: true,
      message: 'Preferințele au fost primite cu succes. Veți fi contactat în curând.' 
    });
  } catch (error) {
    console.error('Error processing preferences:', error);
    return NextResponse.json(
      { success: false, message: 'A apărut o eroare la procesarea cererii.' },
      { status: 500 }
    );
  }
}