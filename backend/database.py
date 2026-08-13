import os
from datetime import datetime, timezone
from sqlalchemy import Column,DateTime,Float,ForeignKey,Integer,String,Boolean,UniqueConstraint,create_engine,text
from sqlalchemy.orm import declarative_base,relationship,sessionmaker
BASE_DIR=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
engine=create_engine(f"sqlite:///{os.path.join(BASE_DIR,'gallery.db')}",connect_args={'check_same_thread':False})
SessionLocal=sessionmaker(autocommit=False,autoflush=False,bind=engine)
Base=declarative_base()
def utcnow(): return datetime.now(timezone.utc)
class Image(Base):
 __tablename__='images'
 id=Column(Integer,primary_key=True,index=True); uuid=Column(String,unique=True,index=True); original_filename=Column(String); extension=Column(String); media_type=Column(String,default='image'); mime_type=Column(String,default='application/octet-stream'); status=Column(String,default='pending',index=True); moderation_score=Column(Float); moderation_reason=Column(String); created_at=Column(DateTime,default=utcnow,index=True); reports_count=Column(Integer,default=0); title=Column(String,default=''); description=Column(String,default=''); tags=Column(String,default=''); user_id=Column(Integer,ForeignKey('users.id'),nullable=True); upvotes=Column(Integer,default=0); downvotes=Column(Integer,default=0)
 reports=relationship('Report',back_populates='image',cascade='all, delete-orphan'); user=relationship('User')
class Report(Base):
 __tablename__='reports'; id=Column(Integer,primary_key=True,index=True); image_id=Column(Integer,ForeignKey('images.id'),index=True); reason=Column(String); details=Column(String); created_at=Column(DateTime,default=utcnow); ip_hash=Column(String); image=relationship('Image',back_populates='reports')
class User(Base):
 __tablename__='users'; id=Column(Integer,primary_key=True,index=True); username=Column(String,unique=True,index=True,nullable=False); password_hash=Column(String,nullable=False); is_active=Column(Boolean,default=True,nullable=False); created_at=Column(DateTime,default=utcnow,index=True)
class Vote(Base):
 __tablename__='votes'; id=Column(Integer,primary_key=True); image_id=Column(Integer,ForeignKey('images.id'),nullable=False,index=True); voter_key=Column(String,nullable=False,index=True); value=Column(Integer,nullable=False); created_at=Column(DateTime,default=utcnow); __table_args__=(UniqueConstraint('image_id','voter_key',name='uq_vote_image_voter'),)
class AdminAction(Base):
 __tablename__='admin_actions'; id=Column(Integer,primary_key=True); action=Column(String); image_uuid=Column(String); timestamp=Column(DateTime,default=utcnow)

def migrate():
 Base.metadata.create_all(bind=engine)
 with engine.begin() as conn:
  cols={r[1] for r in conn.execute(text('PRAGMA table_info(images)')).fetchall()}
  additions={'media_type':'VARCHAR DEFAULT \'image\'','mime_type':'VARCHAR DEFAULT \'application/octet-stream\'','title':'VARCHAR DEFAULT \'\'','description':'VARCHAR DEFAULT \'\'','tags':'VARCHAR DEFAULT \'\'','user_id':'INTEGER','upvotes':'INTEGER DEFAULT 0','downvotes':'INTEGER DEFAULT 0'}
  for name,typ in additions.items():
   if name not in cols: conn.execute(text(f'ALTER TABLE images ADD COLUMN {name} {typ}'))

def get_db():
 db=SessionLocal()
 try: yield db
 finally: db.close()
def init_db(): migrate()
